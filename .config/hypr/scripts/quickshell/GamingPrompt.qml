import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Pops when a Pro Controller (GuliKit in Switch mode) connects — offers to enter
// gaming focus mode for a chosen duration. Writes the same files the BatteryPopup
// focus selector does (~/.cache/qs_focus_mode + qs_focus_end), so the existing
// countdown/expiry/reset logic handles the rest.
Item {
    id: window

    // Contract props: Main.qml assigns all four on creation (its creation path
    // has no undefined-guards, so missing ones raise non-existent-property errors)
    property var notifModel
    property var liveNotifs
    property real layoutWidth: 0
    property real layoutHeight: 0

    Scaler { id: scaler; currentWidth: Screen.width }
    function s(val) { return scaler.s(val); }

    MatugenColors { id: _theme }
    readonly property color base:     _theme.base
    readonly property color text:     _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color overlay0: _theme.overlay0
    readonly property color overlay1: _theme.overlay1
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color green:    _theme.green
    readonly property color red:      _theme.red

    // ── State ──
    property int setMins: 60

    readonly property string timeStr: {
        if (setMins <= 0) return "—";
        let h = Math.floor(setMins / 60);
        let m = setMins % 60;
        return h + ":" + (m < 10 ? "0" : "") + m;
    }

    function startGaming() {
        if (setMins <= 0) { closePopup(); return; }
        Quickshell.execDetached(["bash", "-c",
            "echo gaming > ~/.cache/qs_focus_mode; " +
            "echo $(( $(date +%s) + " + (setMins * 60) + " )) > ~/.cache/qs_focus_end"
        ]);
        closePopup();
    }

    function closePopup() {
        Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh close"]);
    }

    // Controller navigation: the gaming_prompt_controller reader maps the D-pad to
    // these IPC calls while the popup is open (QML Keys can't see gamepad evdev).
    //   left = more time · right = less time · up = start · down = cancel
    IpcHandler {
        target: "gaming"
        function addTime(): void { window.setMins = Math.min(360, window.setMins + 15) }
        function subTime(): void { window.setMins = Math.max(15, window.setMins - 15) }
        function confirm(): void { window.startGaming() }
        function cancel(): void { window.closePopup() }
    }

    // ── Intro ──
    property real introMain: 0
    NumberAnimation on introMain { from: 0; to: 1.0; duration: 500; easing.type: Easing.OutBack; easing.overshoot: 1.2 }

    // Shared clock for the glow pulse (2s period, matches the old animation)
    property real pulsePhase: 0
    Timer {
        interval: 50; repeat: true; running: window.visible
        onTriggered: window.pulsePhase = (window.pulsePhase + Math.PI * 2 * 50 / 2000) % (Math.PI * 2)
    }

    Item {
        anchors.fill: parent
        scale: 0.9 + (0.1 * introMain)
        opacity: introMain

        Rectangle {
            anchors.fill: parent
            radius: window.s(18)
            color: window.base
            border.color: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.3)
            border.width: 2
            clip: true

            // Pulsing red glow — timer-stepped at 20fps and visible-gated
            // (the old Infinite animation kept rendering at full frame rate
            // 24/7 once Main.qml cached this widget hidden). The cosine is the
            // exact waveform the two InOutSine halves composed into.
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                color: "transparent"
                border.color: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.15)
                border.width: window.s(6) - Math.cos(window.pulsePhase) * window.s(2)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.s(16)
                spacing: window.s(10)

                // Title
                Text {
                    text: "󰊴  Controller connected"
                    font.family: "Iosevka Nerd Font"; font.weight: Font.Bold; font.pixelSize: window.s(13)
                    color: window.red
                    Layout.alignment: Qt.AlignHCenter
                }

                Text {
                    text: "Enter gaming mode?"
                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                    color: window.subtext0
                    Layout.alignment: Qt.AlignHCenter
                }

                // Duration display
                Text {
                    text: window.timeStr
                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(32)
                    color: window.text
                    Layout.alignment: Qt.AlignHCenter
                }

                // Duration stepper: [-] [1:00] [+]
                RowLayout {
                    Layout.fillWidth: true
                    spacing: window.s(6)

                    Rectangle {
                        Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36)
                        radius: window.s(8)
                        color: gMinMa.containsMouse ? window.surface1 : window.surface0
                        border.color: window.surface1; border.width: 1
                        Text {
                            anchors.centerIn: parent; text: "-"
                            font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(18)
                            color: gMinMa.containsMouse ? window.text : window.subtext0
                        }
                        MouseArea { id: gMinMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.setMins = Math.max(15, window.setMins - 15) }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(36)
                        radius: window.s(8); color: window.surface0; border.color: window.surface1; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: window.setMins + " min"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(14)
                            color: window.red
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36)
                        radius: window.s(8)
                        color: gPlsMa.containsMouse ? window.surface1 : window.surface0
                        border.color: window.surface1; border.width: 1
                        Text {
                            anchors.centerIn: parent; text: "+"
                            font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(18)
                            color: gPlsMa.containsMouse ? window.text : window.subtext0
                        }
                        MouseArea { id: gPlsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.setMins = Math.min(360, window.setMins + 15) }
                    }
                }

                // Start / Dismiss
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(8)

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(34)
                        radius: window.s(8)
                        color: startMa.containsMouse ? Qt.rgba(window.red.r, window.red.g, window.red.b, 0.2) : window.surface0
                        border.color: startMa.containsMouse ? window.red : window.surface1; border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent; text: "Start"
                            font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(12)
                            color: startMa.containsMouse ? window.red : window.subtext0
                        }
                        MouseArea { id: startMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.startGaming() }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(34)
                        radius: window.s(8)
                        color: dismissMa.containsMouse ? window.surface1 : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text {
                            anchors.centerIn: parent; text: "Not now"
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                            color: dismissMa.containsMouse ? window.text : window.overlay0
                        }
                        MouseArea { id: dismissMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.closePopup() }
                    }
                }
            }
        }
    }
}
