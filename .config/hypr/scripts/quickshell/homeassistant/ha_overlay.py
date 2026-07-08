#!/usr/bin/env python3
"""
Transparent Qt WebEngine window for the Home Assistant dashboard.

Quickshell can't host QtWebEngine in-process, so (exactly like the Matrix Element
overlay) this runs as a sibling frameless, transparent QtQuick window rendering
the Home Assistant Lovelace UI. Hyprland window-rules float/size/position it; its
own QML draws the matugen background behind the web view.

Window identity for Hyprland windowrule:  app_id/class = home-assistant-overlay
"""
import json
import os
import subprocess
import sys

from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlApplicationEngine
from PyQt6.QtWebEngineQuick import QtWebEngineQuick

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get("HA_URL", "http://10.0.0.15:8123")
QML = os.path.join(HERE, "ha_overlay.qml")
INJECT_JS = os.path.join(HERE, "ha_transparent.js")
COLORS_JSON = os.path.join(HERE, "..", "qs_colors.json")  # live matugen palette


def load_colors():
    try:
        with open(COLORS_JSON, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def main():
    # Keep Chromium painting while the overlay is UNFOCUSED (otherwise the
    # unfocused surface clears to opaque black over the matugen). Set before
    # QtWebEngineQuick.initialize().
    _flags = ("--disable-renderer-backgrounding "
              "--disable-backgrounding-occluded-windows "
              "--disable-background-timer-throttling")
    os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (
        os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "") + " " + _flags).strip()

    QtWebEngineQuick.initialize()
    app = QGuiApplication(sys.argv)
    app.setApplicationName("home-assistant-overlay")
    app.setDesktopFileName("home-assistant-overlay")  # -> Wayland app_id / Hyprland class

    try:
        with open(INJECT_JS, "r") as f:
            inject_js = f.read()
    except Exception:
        inject_js = ""
    # Prepend the live matugen palette so the injected CSS can theme HA surfaces.
    inject_js = "window.QS_COLORS = " + json.dumps(load_colors()) + ";\n" + inject_js

    engine = QQmlApplicationEngine()
    ctx = engine.rootContext()
    ctx.setContextProperty("haUrl", URL)
    ctx.setContextProperty("injectJs", inject_js)
    ctx.setContextProperty("qsColors", load_colors())
    engine.load(QML)
    if not engine.rootObjects():
        sys.stderr.write("ha_overlay: failed to load QML\n")
        sys.exit(1)

    # ── Click-outside-to-close: park on the hidden workspace when focus is lost,
    # so HA stays loaded (no reload). Only arms after the window has been focused
    # once, so it never insta-hides on map.
    root = engine.rootObjects()[0]
    toggle_sh = os.path.join(HERE, "ha_toggle.sh")
    seen_active = {"v": False}

    hide_timer = QTimer()
    hide_timer.setSingleShot(True)
    hide_timer.setInterval(160)

    def do_hide():
        if not root.isActive():
            subprocess.Popen(["bash", toggle_sh, "close"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def on_active_changed():
        if root.isActive():
            seen_active["v"] = True
            hide_timer.stop()
        elif seen_active["v"]:
            hide_timer.start()

    hide_timer.timeout.connect(do_hide)
    root.activeChanged.connect(on_active_changed)

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
