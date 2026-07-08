#!/usr/bin/env python3
"""
Transparent Qt WebEngine window for the Quickshell Matrix panel.

Quickshell can't host QtWebEngine in-process (it never calls
QtWebEngineQuick.initialize(), so Chromium aborts). This runs as a sibling
frameless, fully transparent QtQuick window rendering the local Element Web
instance (element-matrix.service quadlet, 127.0.0.1:8420). Hyprland window-rules
float/position it over the Matrix panel; the panel's QML draws the visible
(app-launcher-style) background behind it.

Uses the QtQuick WebEngineView (not the widgets QWebEngineView) because its
backgroundColor:"transparent" on a transparent Window is the reliable Wayland
transparency path.

Window identity for Hyprland windowrulev2:  app_id/class = element-matrix-overlay
"""
import json
import os
import sys

from PyQt6.QtCore import QMetaObject, QProcess, QTimer
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlApplicationEngine
from PyQt6.QtWebEngineQuick import QtWebEngineQuick

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get("ELEMENT_URL", "http://127.0.0.1:8420")
QML = os.path.join(HERE, "element_overlay.qml")
INJECT_JS = os.path.join(HERE, "element_transparent.js")
COLORS_JSON = os.path.join(HERE, "..", "qs_colors.json")  # canonical live matugen palette


def load_colors():
    try:
        with open(COLORS_JSON, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def main():
    # Keep Chromium painting while the overlay is UNFOCUSED. By default Chromium
    # treats an unfocused/occluded window as "backgrounded" and stops compositing
    # it; on Wayland that non-painting surface clears to OPAQUE BLACK, covering
    # the matugen background (the "goes black when the cursor leaves it"). These
    # flags disable that throttling so the transparent page keeps rendering even
    # without focus. Must be set BEFORE QtWebEngineQuick.initialize().
    #
    # --disable-gpu-compositing: force Chromium to hand its final frame to Qt as a
    # scene-graph texture instead of compositing into its OWN Wayland subsurface.
    # The subsurface path composites ABOVE the QML scene regardless of z-order, so
    # where Element is transparent the subsurface clears to opaque black over the
    # matugen `mainBg` — i.e. "the overlay has no system background". With in-scene
    # rendering, normal QML z-order applies and the base + orbiting blobs show
    # through the transparent page. (Same fix obsidian-shell uses; GPU
    # rasterization of page content is unaffected — only the composite step moves.)
    _flags = ("--disable-renderer-backgrounding "
              "--disable-backgrounding-occluded-windows "
              "--disable-background-timer-throttling "
              "--disable-gpu-compositing")
    os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (
        os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "") + " " + _flags).strip()

    QtWebEngineQuick.initialize()  # MUST run before the QML engine is created
    app = QGuiApplication(sys.argv)
    app.setApplicationName("element-matrix-overlay")
    app.setDesktopFileName("element-matrix-overlay")  # -> Wayland app_id / Hyprland class

    with open(INJECT_JS, "r") as f:
        inject_js = f.read()
    # Prepend the live matugen palette so the injected CSS can colour popovers.
    inject_js = "window.QS_COLORS = " + json.dumps(load_colors()) + ";\n" + inject_js

    engine = QQmlApplicationEngine()
    ctx = engine.rootContext()
    ctx.setContextProperty("elementUrl", URL)
    ctx.setContextProperty("injectJs", inject_js)
    ctx.setContextProperty("qsColors", load_colors())  # matugen palette for the QML background
    # Parked-renderer discard delay (ms). 0 disables. Overridable for testing.
    ctx.setContextProperty("discardMs", int(os.environ.get("ELEMENT_DISCARD_MS", "600000")))
    engine.load(QML)
    if not engine.rootObjects():
        sys.stderr.write("element_overlay: failed to load QML\n")
        sys.exit(1)

    # ── Click-outside-to-close ───────────────────────────────────────────────
    # When the overlay loses focus (the user clicked another window or the
    # desktop), park it on the hidden workspace — the SAME mechanism as the
    # toggle, so Element stays loaded (no reload). A short debounce ignores
    # transient focus blips during load, and we only start auto-hiding once the
    # window has actually been focused, so it never insta-hides on map.
    root = engine.rootObjects()[0]
    toggle_sh = os.path.join(HERE, "matrix_toggle.sh")
    seen_active = {"v": False}

    hide_timer = QTimer()
    hide_timer.setSingleShot(True)
    hide_timer.setInterval(160)

    def do_hide():
        if root.isActive():
            return
        # Travel guard: with focus-follows-mouse the overlay blurs while the
        # pointer travels from the topbar button to it. Until the pointer has
        # actually been inside the window this activation (pointerSeen, set by
        # the QML HoverHandler), fall back to one long grace period instead of
        # the fast 160ms park — reaching the overlay refocuses it and cancels.
        if not root.property("pointerSeen") and hide_timer.interval() == 160:
            hide_timer.setInterval(1600)
            hide_timer.start()
            return
        # Park sequence: raise the matugen cover FIRST so the surface's last
        # committed frame before the unmap is themed (never stale Element
        # pixels), give it a beat to render, then dispatch the park. Raising it
        # here — only when a park actually happens — instead of on every blur
        # is what stops transient focus blips flashing the dark cover.
        QMetaObject.invokeMethod(root, "raiseCover")

        def _park():
            if root.isActive():
                return  # refocused during the beat: revealAfterRepaint fades the cover
            # `close` = "ensure parked on the hidden workspace" (never shows).
            # startDetached double-forks: no zombie to reap, no event-loop block.
            QProcess.startDetached("bash", [toggle_sh, "close"])

        QTimer.singleShot(90, _park)

    def on_active_changed():
        if root.isActive():
            seen_active["v"] = True
            hide_timer.stop()
            hide_timer.setInterval(160)
        elif seen_active["v"]:
            hide_timer.start()

    hide_timer.timeout.connect(do_hide)
    root.activeChanged.connect(on_active_changed)

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
