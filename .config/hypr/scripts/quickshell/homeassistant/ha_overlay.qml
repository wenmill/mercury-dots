import QtQuick
import QtQuick.Window
import QtWebEngine

// Frameless overlay window for the Home Assistant dashboard: a matugen
// background with the HA Lovelace web UI rendered (transparent) on top. One
// toplevel window so the background sits behind the web view. Cloned from the
// Matrix Element overlay (matrix/element_overlay.qml) — same transparency +
// re-show-repaint recipe, just pointed at Home Assistant.
//
// Window identity for Hyprland windowrule: class/app_id = home-assistant-overlay
Window {
    id: win
    visible: true
    // Same footprint as the calendar popup. Calendar width = 1450×sf = 1674; its
    // height is dynamic (510×sf normally, 750×sf with a schedule module) — we match
    // its normal 510×sf = 589. The Hyprland windowrule enforces this size.
    width: 1674
    height: 589
    // Fixed min==max -> non-resizable xdg-toplevel (matches the Hyprland rule).
    minimumWidth: 1674;  maximumWidth: 1674
    minimumHeight: 589;  maximumHeight: 589
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "HomeAssistantOverlay"

    // matugen palette passed from Python (qs_colors.json); fall back to Catppuccin.
    readonly property var c: (typeof qsColors !== "undefined" && qsColors) ? qsColors : ({})
    function col(k, fb) { return c[k] ? c[k] : fb; }

    // ── Force-repaint on re-show (parked surface keeps a stale black buffer) ──
    property int repaintKick: 0
    function raiseCover() { coverFade.stop(); reshowCover.opacity = 1; }
    function revealAfterRepaint() {
        coverFade.stop();
        reshowCover.opacity = 1;
        win.repaintKick = 1;     // 1px resize -> QtWebEngine repaints underneath
        repaintResetTimer.restart();
    }
    onActiveChanged: active ? revealAfterRepaint() : raiseCover()
    Timer {
        id: repaintResetTimer
        interval: 55; repeat: false
        onTriggered: { win.repaintKick = 0; coverFade.start(); }
    }

    // ── matugen background (shows through HA's transparent areas + at corners) ──
    Rectangle {
        id: mainBg
        anchors.fill: parent
        radius: 16
        color: win.col("base", "#1e1e2e")
        border.color: win.col("surface1", "#45475a")
        border.width: 1
        clip: true

        // Timer-stepped at 20fps instead of a per-frame NumberAnimation (which
        // also had no gate at all) — same fix as element_overlay.qml. Gated on
        // win.active: the overlay auto-parks whenever it loses focus, so
        // active tracks "actually on screen".
        property real orbit: 0
        Timer {
            interval: 50; repeat: true; running: win.active
            onTriggered: mainBg.orbit = (mainBg.orbit + Math.PI * 2 * 50 / 90000) % (Math.PI * 2)
        }
        Rectangle {
            width: parent.width * 0.8; height: width; radius: width / 2
            x: (parent.width / 2 - width / 2) + Math.cos(mainBg.orbit * 2) * 140
            y: (parent.height / 2 - height / 2) + Math.sin(mainBg.orbit * 2) * 90
            opacity: 0.08
            color: win.col("mauve", "#cba6f7")
        }
        Rectangle {
            width: parent.width * 0.9; height: width; radius: width / 2
            x: (parent.width / 2 - width / 2) + Math.sin(mainBg.orbit * 1.5) * -140
            y: (parent.height / 2 - height / 2) + Math.cos(mainBg.orbit * 1.5) * -90
            opacity: 0.06
            color: win.col("blue", "#89b4fa")
        }
    }

    // ── Home Assistant on top. Persistent profile so the login survives restarts. ──
    WebEngineProfile {
        id: haProfile
        storageName: "home-assistant"
        offTheRecord: false
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    }

    WebEngineView {
        id: web
        anchors.fill: parent
        anchors.margins: 2 + win.repaintKick   // +1px on re-show forces a repaint
        profile: haProfile
        backgroundColor: "transparent"
        url: haUrl

        // injectJs (ha_transparent.js) makes HA's page background transparent so the
        // matugen shows through, while leaving cards readable. Self-persists via a
        // MutationObserver.
        onLoadingChanged: function(req) {
            if (req.status === WebEngineView.LoadSucceeded)
                web.runJavaScript(injectJs);
        }
        Timer {
            running: true; interval: 700; repeat: true
            property int n: 0
            onTriggered: { web.runJavaScript(injectJs); if (++n > 14) running = false; }
        }
    }

    // ── Re-show cover: hides the parked surface's stale black buffer on re-open. ──
    Rectangle {
        id: reshowCover
        anchors.fill: parent
        anchors.margins: 2
        radius: 14
        color: win.col("base", "#1e1e2e")
        opacity: 0
        visible: opacity > 0.01
        NumberAnimation on opacity {
            id: coverFade
            from: 1; to: 0; duration: 130; running: false; easing.type: Easing.OutCubic
        }
    }
}
