import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import "../"

// Combined "tool hub": App Launcher (left) · Useful Tools (centre) · Clipboard
// (right) in one calendar-sized popup. Each column embeds the EXISTING standalone
// component via a Loader, so all of their UI/logic is reused verbatim — we just
// set `embedded: true` on each, which hides its per-window ToolSwitcher slider
// (pointless when all three are shown at once), yields keyboard focus to the
// launcher, AND swaps its opaque window background for a translucent card so all
// three share the hub's single calendar-style background below.
Item {
    id: hub
    focus: true

    // Main.qml passes these to every widget it creates/reopens; unused here but
    // declared so the assignments don't raise "non-existent property" errors.
    property var notifModel
    property var liveNotifs
    property real layoutWidth: 0
    property real layoutHeight: 0

    Scaler { id: scaler; currentWidth: Screen.width }
    function s(v) { return scaler.s(v); }
    MatugenColors { id: _theme }

    // Shared ambient clock for the background blobs — timer-stepped at 20fps
    // (sub-pixel per step at 2π/90s) and gated on visibility, same as the
    // other popups.
    property real orbitAngle: 0
    Timer {
        interval: 50; repeat: true; running: hub.visible
        onTriggered: hub.orbitAngle = (hub.orbitAngle + Math.PI * 2 * 50 / 90000) % (Math.PI * 2)
    }

    // ── ONE unified background (calendar-style): a single base surface with
    //    ambient blobs spanning the whole hub; the three modules render as
    //    translucent cards on top of it. ──
    Rectangle {
        anchors.fill: parent
        radius: hub.s(20)
        color: _theme.base
        border.color: _theme.surface0
        border.width: 1
        clip: true

        Rectangle {
            width: parent.width * 0.45; height: width; radius: width / 2
            x: (parent.width * 0.30 - width / 2) + Math.cos(hub.orbitAngle * 2) * hub.s(220)
            y: (parent.height * 0.40 - height / 2) + Math.sin(hub.orbitAngle * 2) * hub.s(120)
            opacity: 0.08
            color: _theme.mauve
            Behavior on color { ColorAnimation { duration: 1000 } }
        }
        Rectangle {
            width: parent.width * 0.5; height: width; radius: width / 2
            x: (parent.width * 0.70 - width / 2) + Math.sin(hub.orbitAngle * 1.5) * hub.s(-220)
            y: (parent.height * 0.60 - height / 2) + Math.cos(hub.orbitAngle * 1.5) * hub.s(-120)
            opacity: 0.06
            color: _theme.blue
            Behavior on color { ColorAnimation { duration: 1000 } }
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: hub.s(14)
        spacing: hub.s(12)

        // LEFT — App Launcher (wider)
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: hub.s(540)
            source: Qt.resolvedUrl("appLauncher.qml")
            onLoaded: if (item) item.embedded = true
        }

        // CENTRE — Useful Tools (narrow: shows one tool at a time via ◄ / ► arrows)
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: hub.s(360)
            source: Qt.resolvedUrl("Useful_Tools.qml")
            onLoaded: if (item) item.embedded = true
        }

        // RIGHT — Clipboard (wider)
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: hub.s(540)
            source: Qt.resolvedUrl("ClipboardManager.qml")
            onLoaded: if (item) item.embedded = true
        }
    }
}
