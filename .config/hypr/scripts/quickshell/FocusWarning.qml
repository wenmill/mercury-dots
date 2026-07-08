import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

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
    readonly property color mantle:   _theme.mantle
    readonly property color crust:    _theme.crust
    readonly property color text:     _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color overlay0: _theme.overlay0
    readonly property color overlay1: _theme.overlay1
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color green:    _theme.green
    readonly property color red:      _theme.red
    readonly property color yellow:   _theme.yellow
    readonly property color teal:     _theme.teal

    // ── State ──
    property int remainSec: 0
    property int addMins: 15

    // Read current remaining time
    Process {
        id: endReader; running: true
        command: ["bash", "-c", "cat ~/.cache/qs_focus_end 2>/dev/null || echo 0"]
        stdout: StdioCollector {
            onStreamFinished: {
                let end = parseInt(this.text.trim()) || 0;
                let now = Math.floor(Date.now() / 1000);
                window.remainSec = Math.max(0, end - now);
            }
        }
    }

    // Main.qml caches this widget hidden after first use, so re-sync the
    // countdown from qs_focus_end every time it is shown again — the cached
    // remainSec is stale by the second warning.
    onVisibleChanged: if (visible) { endReader.running = false; endReader.running = true; }

    // Update countdown (only while shown; hidden it just goes stale and the
    // re-sync above corrects it on reopen)
    Timer {
        interval: 1000; repeat: true; running: window.visible
        onTriggered: {
            if (window.remainSec > 0) window.remainSec--;
        }
    }

    // Format time
    readonly property string timeStr: {
        let m = Math.floor(remainSec / 60);
        let s = remainSec % 60;
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    function addTime() {
        Quickshell.execDetached(["bash", "-c",
            "END=$(cat ~/.cache/qs_focus_end 2>/dev/null || echo 0); " +
            "NEW=$((END + " + (addMins * 60) + ")); " +
            "echo $NEW > ~/.cache/qs_focus_end"
        ]);
        window.remainSec += addMins * 60;
    }

    function endNow() {
        Quickshell.execDetached(["bash", "-c",
            "echo default > ~/.cache/qs_focus_mode; echo 0 > ~/.cache/qs_focus_end"
        ]);
        Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh close"]);
    }

    function closePopup() {
        Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh close"]);
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
            border.color: Qt.rgba(window.green.r, window.green.g, window.green.b, 0.3)
            border.width: 2
            clip: true

            // Pulsing green glow — timer-stepped at 20fps and visible-gated
            // (the old Infinite animation kept rendering at full frame rate
            // 24/7 once Main.qml cached this widget hidden). The cosine is the
            // exact waveform the two InOutSine halves composed into.
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                color: "transparent"
                border.color: Qt.rgba(window.green.r, window.green.g, window.green.b, 0.15)
                border.width: window.s(6) - Math.cos(window.pulsePhase) * window.s(2)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.s(16)
                spacing: window.s(10)

                // Title
                Text {
                    text: "Study session ending soon"
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13)
                    color: window.green
                    Layout.alignment: Qt.AlignHCenter
                }

                // Countdown
                Text {
                    text: window.timeStr
                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(32)
                    color: window.text
                    Layout.alignment: Qt.AlignHCenter
                }

                // Add time controls: [-] [15 min] [+] [Add]
                RowLayout {
                    Layout.fillWidth: true
                    spacing: window.s(6)

                    // Minus
                    Rectangle {
                        Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36)
                        radius: window.s(8)
                        color: wMinMa.containsMouse ? window.surface1 : window.surface0
                        border.color: window.surface1; border.width: 1
                        Text {
                            anchors.centerIn: parent; text: "-"
                            font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(18)
                            color: wMinMa.containsMouse ? window.text : window.subtext0
                        }
                        MouseArea { id: wMinMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.addMins = Math.max(5, window.addMins - 5) }
                    }

                    // Time to add
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(36)
                        radius: window.s(8); color: window.surface0; border.color: window.surface1; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "+" + window.addMins + " min"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(14)
                            color: window.green
                        }
                    }

                    // Plus
                    Rectangle {
                        Layout.preferredWidth: window.s(36); Layout.preferredHeight: window.s(36)
                        radius: window.s(8)
                        color: wPlsMa.containsMouse ? window.surface1 : window.surface0
                        border.color: window.surface1; border.width: 1
                        Text {
                            anchors.centerIn: parent; text: "+"
                            font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(18)
                            color: wPlsMa.containsMouse ? window.text : window.subtext0
                        }
                        MouseArea { id: wPlsMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.addMins = Math.min(120, window.addMins + 5) }
                    }

                    // Add button
                    Rectangle {
                        Layout.preferredWidth: window.s(60); Layout.preferredHeight: window.s(36)
                        radius: window.s(8)
                        color: addBtnMa.containsMouse ? Qt.rgba(window.green.r, window.green.g, window.green.b, 0.2) : window.surface0
                        border.color: addBtnMa.containsMouse ? window.green : window.surface1; border.width: 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Text {
                            anchors.centerIn: parent; text: "Add"
                            font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: window.s(12)
                            color: addBtnMa.containsMouse ? window.green : window.subtext0
                        }
                        MouseArea {
                            id: addBtnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { window.addTime(); window.closePopup(); }
                        }
                    }
                }

                // End now / Dismiss
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(8)

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(30)
                        radius: window.s(8)
                        color: endMa.containsMouse ? Qt.rgba(window.red.r, window.red.g, window.red.b, 0.15) : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text {
                            anchors.centerIn: parent; text: "End now"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(11)
                            color: endMa.containsMouse ? window.red : window.overlay0
                        }
                        MouseArea { id: endMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.endNow() }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(30)
                        radius: window.s(8)
                        color: dismissMa.containsMouse ? window.surface1 : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text {
                            anchors.centerIn: parent; text: "Dismiss"
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
