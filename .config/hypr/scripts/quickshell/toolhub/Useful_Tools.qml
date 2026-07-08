import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "../"

// =============================================================================
// Useful_Tools.qml — opened from the app launcher's right-click.
//   • LEFT  : Timer / Alarm / Stopwatch (Apple-Clock-style)
//   • RIGHT : Calculator (Apple-Calculator-style)
// Matugen palette. Timer completion + alarm triggers fire a real desktop
// notification and a sound. All state lives at the root with explicit ids
// (no fragile parent.parent chains).
// =============================================================================
Item {
    id: window
    focus: true

    // Set true by the combined ToolHub's Loader. When embedded, the per-window
    // tool slider bar collapses (all three tools are shown side-by-side).
    property bool embedded: false

    Scaler { id: scaler; currentWidth: Screen.width }
    function s(v) { return scaler.s(v); }

    MatugenColors { id: _theme }
    readonly property color base: _theme.base
    readonly property color mantle: _theme.mantle
    readonly property color crust: _theme.crust
    readonly property color text: _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color mauve: _theme.mauve
    readonly property color peach: _theme.peach
    readonly property color green: _theme.green
    readonly property color red: _theme.red
    readonly property color blue: _theme.blue
    readonly property color yellow: _theme.yellow
    readonly property color teal: _theme.teal

    Shortcut { sequence: "Escape"; onActivated: Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/qs_manager.sh", "close", "tools"]) }

    function pad2(n) { return (n < 10 ? "0" : "") + Math.floor(n); }

    // ── Alerts ────────────────────────────────────────────────────────────────
    Process { id: notifyProc; command: ["bash", "-c", "true"] }
    function alert(title, body) {
        var cmd = "notify-send -a 'Tools' -u critical '" + title.replace(/'/g, "") + "' '" + body.replace(/'/g, "") + "'; " +
                  "(paplay /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga 2>/dev/null || " +
                  "paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || " +
                  "canberra-gtk-play -i alarm-clock-elapsed 2>/dev/null) &";
        notifyProc.command = ["bash", "-c", cmd];
        notifyProc.running = false; notifyProc.running = true;
    }

    // =========================================================================
    // STATE (root-level, explicit ids)
    // =========================================================================
    QtObject {
        id: timerState
        property int total: 0       // configured seconds
        property int remain: 0      // remaining seconds
        property bool running: false
    }
    QtObject {
        id: swState
        property int ms: 0
        property bool running: false
        property var laps: []
    }
    QtObject {
        id: alarmState
        property var list: []       // [{h,m,on}]
        property int newH: 7
        property int newM: 0
    }
    QtObject {
        id: calc
        property string display: "0"
        property real accumulator: 0
        property string pendingOp: ""
        property bool freshEntry: true
    }

    function calcStep(a, b, op) {
        if (op === "+") return a + b;
        if (op === "−") return a - b;
        if (op === "×") return a * b;
        if (op === "÷") return b === 0 ? NaN : a / b;
        return b;
    }
    function fmtNum(n) {
        if (isNaN(n) || !isFinite(n)) return "Error";
        var a = Math.abs(n);
        // Compact exponential for magnitudes that would otherwise be a huge digit string.
        if (a !== 0 && (a >= 1e15 || a < 1e-9)) return n.toExponential(6).replace(/\.?0+e/, "e");
        return "" + (Math.round(n * 1e10) / 1e10);
    }
    function calcDigit(d) {
        if (calc.display === "Error") calc.display = "0";
        if (calc.freshEntry || calc.display === "0") { calc.display = (d === "." ? "0." : d); calc.freshEntry = false; }
        else { if (d === "." && calc.display.indexOf(".") >= 0) return; calc.display = calc.display + d; }
    }
    function calcOp(op) {
        var cur = parseFloat(calc.display);
        if (calc.pendingOp !== "" && !calc.freshEntry) { calc.accumulator = calcStep(calc.accumulator, cur, calc.pendingOp); calc.display = fmtNum(calc.accumulator); }
        else { calc.accumulator = cur; }
        calc.pendingOp = op; calc.freshEntry = true;
    }
    function calcEquals() {
        if (calc.pendingOp === "") return;
        calc.accumulator = calcStep(calc.accumulator, parseFloat(calc.display), calc.pendingOp);
        calc.display = fmtNum(calc.accumulator); calc.pendingOp = ""; calc.freshEntry = true;
    }
    function calcClear() { calc.display = "0"; calc.accumulator = 0; calc.pendingOp = ""; calc.freshEntry = true; }
    function calcNeg() { calc.display = fmtNum(parseFloat(calc.display) * -1); }
    function calcPct() { calc.display = fmtNum(parseFloat(calc.display) / 100); calc.freshEntry = true; }

    function swText(ms) {
        return pad2(Math.floor(ms/60000)) + ":" + pad2(Math.floor((ms%60000)/1000)) + "." + (Math.floor((ms%1000)/10) < 10 ? "0" : "") + Math.floor((ms%1000)/10);
    }
    function timerText(sec) {
        var h = Math.floor(sec/3600), m = Math.floor((sec%3600)/60), x = Math.floor(sec%60);
        return (h > 0 ? pad2(h) + ":" : "") + pad2(m) + ":" + pad2(x);
    }

    // left-pane mode
    property string clockMode: "timer"

    // Which tool the (narrow) column shows: 0 = Clock, 1 = Calculator. Switched
    // with the ◄ / ► arrows so the column stays narrow (one tool at a time).
    property int toolPage: 0
    readonly property var toolNames: ["Clock", "Calculator"]
    readonly property int toolCount: toolNames.length

    // ── Timers ─────────────────────────────────────────────────────────────────
    Timer {
        id: timerTick; interval: 1000; repeat: true; running: timerState.running
        onTriggered: {
            if (timerState.remain > 0) timerState.remain--;
            if (timerState.remain <= 0) {
                timerState.running = false;
                window.alert("Timer finished", "Your " + window.timerText(timerState.total) + " timer is done.");
            }
        }
    }
    Timer { id: swTick; interval: 30; repeat: true; running: swState.running; onTriggered: swState.ms += 30 }

    // Alarm checker — fires when wall-clock hits an enabled alarm (once/minute).
    property string lastAlarmFire: ""
    Timer {
        id: alarmTick; interval: 1000; repeat: true; running: true
        onTriggered: {
            var now = new Date();
            var key = window.pad2(now.getHours()) + ":" + window.pad2(now.getMinutes());
            if (now.getSeconds() !== 0) return;
            if (key === window.lastAlarmFire) return;
            for (var i = 0; i < alarmState.list.length; i++) {
                var a = alarmState.list[i];
                if (a.on && window.pad2(a.h) + ":" + window.pad2(a.m) === key) {
                    window.lastAlarmFire = key;
                    window.alert("Alarm", "It's " + key + ".");
                    break;
                }
            }
        }
    }

    // =========================================================================
    // UI
    // =========================================================================
    Rectangle {
        anchors.fill: parent
        radius: window.s(20)
        // Embedded → translucent card over the hub's shared background.
        color: window.embedded ? Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.2) : window.base
        border.color: window.embedded ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.4) : window.surface1
        border.width: 1
        clip: true

        ColumnLayout {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: window.s(16)
            spacing: window.s(12)

            // ── Tool switcher: ◄  Name  ► (shows ONE tool at a time so the column
            //    stays narrow). Clock and Calculator below are stacked — only the
            //    selected one is visible, and (being a Layout child) the hidden one
            //    takes no space, so the visible one fills the area. ──
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: window.s(40)
                // Pin the header height: without this the arrows' Layout.fillHeight
                // propagates an "expanding" vertical policy to this nested RowLayout,
                // so it would eat the whole column.
                Layout.fillHeight: false
                spacing: window.s(8)
                Rectangle {
                    Layout.preferredWidth: window.s(44); Layout.fillHeight: true
                    radius: window.s(12); color: lArrow.containsMouse ? window.surface1 : window.surface0
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text { anchors.centerIn: parent; text: "󰅁"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(18); color: window.text }
                    MouseArea { id: lArrow; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: window.toolPage = (window.toolPage + window.toolCount - 1) % window.toolCount }
                }
                Text {
                    Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                    text: window.toolNames[window.toolPage]
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(15); color: window.text
                }
                Rectangle {
                    Layout.preferredWidth: window.s(44); Layout.fillHeight: true
                    radius: window.s(12); color: rArrow.containsMouse ? window.surface1 : window.surface0
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text { anchors.centerIn: parent; text: "󰅂"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(18); color: window.text }
                    MouseArea { id: rArrow; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: window.toolPage = (window.toolPage + 1) % window.toolCount }
                }
            }

            // =============================================================
            // CLOCK (tool 0)
            // =============================================================
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: window.toolPage === 0
                radius: window.s(16)
                color: window.mantle

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: window.s(16)
                    spacing: window.s(14)

                    // Mode switcher
                    Rectangle {
                        Layout.fillWidth: true; height: window.s(40); radius: window.s(12); color: window.surface0
                        RowLayout {
                            anchors.fill: parent; anchors.margins: window.s(4); spacing: window.s(4)
                            Repeater {
                                model: [ {k:"timer",t:"Timer"}, {k:"alarm",t:"Alarm"}, {k:"stopwatch",t:"Stopwatch"} ]
                                delegate: Rectangle {
                                    Layout.fillWidth: true; Layout.fillHeight: true; radius: window.s(9)
                                    color: window.clockMode === modelData.k ? window.mauve : (mSw.containsMouse ? window.surface1 : "transparent")
                                    Text { anchors.centerIn: parent; text: modelData.t
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(12)
                                        color: window.clockMode === modelData.k ? window.crust : window.subtext0 }
                                    MouseArea { id: mSw; anchors.fill: parent; hoverEnabled: true; onClicked: window.clockMode = modelData.k }
                                }
                            }
                        }
                    }

                    // ---- TIMER ----
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: window.s(12)
                        visible: window.clockMode === "timer"

                        Text {
                            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: window.s(10)
                            text: window.timerText((timerState.running || timerState.remain > 0) ? timerState.remain : timerState.total)
                            font.family: "JetBrains Mono"; font.weight: Font.Thin; font.pixelSize: window.s(52); color: window.text
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter; spacing: window.s(10)
                            visible: !timerState.running && timerState.remain === 0
                            Repeater {
                                model: [ {lbl:"H",mul:3600}, {lbl:"M",mul:60}, {lbl:"S",mul:1} ]
                                delegate: ColumnLayout {
                                    spacing: window.s(4)
                                    Text { Layout.alignment: Qt.AlignHCenter; text: modelData.lbl
                                        font.family: "JetBrains Mono"; font.pixelSize: window.s(10); color: window.subtext0 }
                                    Rectangle { Layout.alignment: Qt.AlignHCenter; width: window.s(40); height: window.s(28); radius: window.s(8)
                                        color: tU.containsMouse ? window.surface2 : window.surface0
                                        Text { anchors.centerIn: parent; text: "+"; font.family: "JetBrains Mono"; font.pixelSize: window.s(16); color: window.text }
                                        MouseArea { id: tU; anchors.fill: parent; hoverEnabled: true; onClicked: timerState.total += modelData.mul } }
                                    Text { Layout.alignment: Qt.AlignHCenter
                                        text: window.pad2(Math.floor(timerState.total / modelData.mul) % (modelData.mul === 3600 ? 100 : 60))
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(20); color: window.text }
                                    Rectangle { Layout.alignment: Qt.AlignHCenter; width: window.s(40); height: window.s(28); radius: window.s(8)
                                        color: tD.containsMouse ? window.surface2 : window.surface0
                                        Text { anchors.centerIn: parent; text: "−"; font.family: "JetBrains Mono"; font.pixelSize: window.s(16); color: window.text }
                                        MouseArea { id: tD; anchors.fill: parent; hoverEnabled: true; onClicked: { if (timerState.total >= modelData.mul) timerState.total -= modelData.mul; } } }
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }

                        RowLayout {
                            Layout.fillWidth: true; spacing: window.s(10)
                            Rectangle {
                                Layout.fillWidth: true; height: window.s(44); radius: window.s(12)
                                color: tCancel.containsMouse ? window.surface2 : window.surface0
                                Text { anchors.centerIn: parent; text: "Cancel"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13); color: window.text }
                                MouseArea { id: tCancel; anchors.fill: parent; hoverEnabled: true
                                    onClicked: { timerState.running = false; timerState.remain = 0; timerState.total = 0; } }
                            }
                            Rectangle {
                                Layout.fillWidth: true; height: window.s(44); radius: window.s(12)
                                color: timerState.running ? window.peach : window.green
                                opacity: tStart.containsMouse ? 0.85 : 1.0
                                Text { anchors.centerIn: parent
                                    text: timerState.running ? "Pause" : (timerState.remain > 0 ? "Resume" : "Start")
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13); color: window.crust }
                                MouseArea { id: tStart; anchors.fill: parent; hoverEnabled: true
                                    onClicked: {
                                        if (timerState.running) { timerState.running = false; }
                                        else {
                                            if (timerState.remain <= 0) timerState.remain = timerState.total;
                                            if (timerState.remain > 0) timerState.running = true;
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---- STOPWATCH ----
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: window.s(12)
                        visible: window.clockMode === "stopwatch"

                        Text { Layout.alignment: Qt.AlignHCenter; Layout.topMargin: window.s(10)
                            text: window.swText(swState.ms)
                            font.family: "JetBrains Mono"; font.weight: Font.Thin; font.pixelSize: window.s(46); color: window.text }

                        ListView {
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: window.s(4)
                            model: swState.laps
                            delegate: Rectangle {
                                width: ListView.view.width; height: window.s(30); radius: window.s(8); color: window.surface0
                                RowLayout { anchors.fill: parent; anchors.leftMargin: window.s(10); anchors.rightMargin: window.s(10)
                                    Text { Layout.fillWidth: true; text: "Lap " + (swState.laps.length - index)
                                        font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0 }
                                    Text { text: modelData; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(11); color: window.text } }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true; spacing: window.s(10)
                            Rectangle {
                                Layout.fillWidth: true; height: window.s(44); radius: window.s(12)
                                color: swLap.containsMouse ? window.surface2 : window.surface0
                                Text { anchors.centerIn: parent; text: swState.running ? "Lap" : "Reset"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13); color: window.text }
                                MouseArea { id: swLap; anchors.fill: parent; hoverEnabled: true
                                    onClicked: {
                                        if (swState.running) { var l = swState.laps.slice(); l.unshift(window.swText(swState.ms)); swState.laps = l; }
                                        else { swState.ms = 0; swState.laps = []; }
                                    }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true; height: window.s(44); radius: window.s(12)
                                color: swState.running ? window.red : window.green
                                opacity: swStart.containsMouse ? 0.85 : 1.0
                                Text { anchors.centerIn: parent; text: swState.running ? "Stop" : "Start"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(13); color: window.crust }
                                MouseArea { id: swStart; anchors.fill: parent; hoverEnabled: true; onClicked: swState.running = !swState.running }
                            }
                        }
                    }

                    // ---- ALARM ----
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: window.s(12)
                        visible: window.clockMode === "alarm"

                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: window.s(8); spacing: window.s(6)
                            ColumnLayout { spacing: window.s(2)
                                Rectangle { Layout.alignment: Qt.AlignHCenter; width: window.s(46); height: window.s(24); radius: window.s(7); color: aHU.containsMouse ? window.surface2 : window.surface0
                                    Text { anchors.centerIn: parent; text: "+"; font.family: "JetBrains Mono"; color: window.text }
                                    MouseArea { id: aHU; anchors.fill: parent; hoverEnabled: true; onClicked: alarmState.newH = (alarmState.newH + 1) % 24 } }
                                Text { Layout.alignment: Qt.AlignHCenter; text: window.pad2(alarmState.newH)
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(30); color: window.text }
                                Rectangle { Layout.alignment: Qt.AlignHCenter; width: window.s(46); height: window.s(24); radius: window.s(7); color: aHD.containsMouse ? window.surface2 : window.surface0
                                    Text { anchors.centerIn: parent; text: "−"; font.family: "JetBrains Mono"; color: window.text }
                                    MouseArea { id: aHD; anchors.fill: parent; hoverEnabled: true; onClicked: alarmState.newH = (alarmState.newH + 23) % 24 } }
                            }
                            Text { text: ":"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(30); color: window.text }
                            ColumnLayout { spacing: window.s(2)
                                Rectangle { Layout.alignment: Qt.AlignHCenter; width: window.s(46); height: window.s(24); radius: window.s(7); color: aMU.containsMouse ? window.surface2 : window.surface0
                                    Text { anchors.centerIn: parent; text: "+"; font.family: "JetBrains Mono"; color: window.text }
                                    MouseArea { id: aMU; anchors.fill: parent; hoverEnabled: true; onClicked: alarmState.newM = (alarmState.newM + 1) % 60 } }
                                Text { Layout.alignment: Qt.AlignHCenter; text: window.pad2(alarmState.newM)
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(30); color: window.text }
                                Rectangle { Layout.alignment: Qt.AlignHCenter; width: window.s(46); height: window.s(24); radius: window.s(7); color: aMD.containsMouse ? window.surface2 : window.surface0
                                    Text { anchors.centerIn: parent; text: "−"; font.family: "JetBrains Mono"; color: window.text }
                                    MouseArea { id: aMD; anchors.fill: parent; hoverEnabled: true; onClicked: alarmState.newM = (alarmState.newM + 59) % 60 } }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: window.s(38); radius: window.s(11)
                            color: aAdd.containsMouse ? window.mauve : window.surface0
                            Text { anchors.centerIn: parent; text: "+ Add alarm"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(12); color: aAdd.containsMouse ? window.crust : window.text }
                            MouseArea { id: aAdd; anchors.fill: parent; hoverEnabled: true
                                onClicked: { var a = alarmState.list.slice(); a.push({h: alarmState.newH, m: alarmState.newM, on: true}); alarmState.list = a; } }
                        }

                        ListView {
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: window.s(6)
                            model: alarmState.list
                            delegate: Rectangle {
                                width: ListView.view.width; height: window.s(46); radius: window.s(10); color: window.surface0
                                RowLayout { anchors.fill: parent; anchors.leftMargin: window.s(12); anchors.rightMargin: window.s(10)
                                    Text { Layout.fillWidth: true; text: window.pad2(modelData.h) + ":" + window.pad2(modelData.m)
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(20)
                                        color: modelData.on ? window.text : window.subtext0 }
                                    Rectangle { width: window.s(44); height: window.s(24); radius: window.s(12)
                                        color: modelData.on ? window.green : window.surface2
                                        Rectangle { width: window.s(18); height: window.s(18); radius: window.s(9); color: window.crust
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: modelData.on ? parent.width - width - window.s(3) : window.s(3)
                                            Behavior on x { NumberAnimation { duration: 120 } } }
                                        MouseArea { anchors.fill: parent
                                            onClicked: { var a = alarmState.list.slice(); a[index].on = !a[index].on; alarmState.list = a; } } }
                                    Rectangle { width: window.s(28); height: window.s(28); radius: window.s(8); color: aDel.containsMouse ? window.red : "transparent"
                                        Text { anchors.centerIn: parent; text: "󰩹"; font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(14); color: aDel.containsMouse ? window.crust : window.subtext0 }
                                        MouseArea { id: aDel; anchors.fill: parent; hoverEnabled: true
                                            onClicked: { var a = alarmState.list.slice(); a.splice(index, 1); alarmState.list = a; } } }
                                }
                            }
                        }
                    }
                }
            }

            // =============================================================
            // CALCULATOR (tool 1)
            // =============================================================
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true
                visible: window.toolPage === 1
                radius: window.s(16); color: window.mantle

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: window.s(16); spacing: window.s(12)

                    Item {
                        Layout.fillWidth: true; Layout.preferredHeight: window.s(90)
                        Text {
                            anchors.right: parent.right; anchors.bottom: parent.bottom; width: parent.width
                            text: calc.display
                            font.family: "JetBrains Mono"; font.weight: Font.Thin; font.pixelSize: window.s(56); color: window.text
                            // Shrink a long result down to fit the width instead of truncating it.
                            fontSizeMode: Text.HorizontalFit; minimumPixelSize: window.s(16)
                            elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight
                        }
                    }

                    GridLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        columns: 4; rowSpacing: window.s(10); columnSpacing: window.s(10)
                        Repeater {
                            model: [
                                {t:"AC",k:"clear",c:"fn"}, {t:"±",k:"neg",c:"fn"}, {t:"%",k:"pct",c:"fn"}, {t:"÷",k:"op",c:"op"},
                                {t:"7",k:"d",c:"num"}, {t:"8",k:"d",c:"num"}, {t:"9",k:"d",c:"num"}, {t:"×",k:"op",c:"op"},
                                {t:"4",k:"d",c:"num"}, {t:"5",k:"d",c:"num"}, {t:"6",k:"d",c:"num"}, {t:"−",k:"op",c:"op"},
                                {t:"1",k:"d",c:"num"}, {t:"2",k:"d",c:"num"}, {t:"3",k:"d",c:"num"}, {t:"+",k:"op",c:"op"},
                                {t:"0",k:"d",c:"num",wide:true}, {t:".",k:"d",c:"num"}, {t:"=",k:"eq",c:"op"}
                            ]
                            delegate: Rectangle {
                                Layout.fillWidth: true; Layout.fillHeight: true
                                Layout.columnSpan: (modelData.wide === true) ? 2 : 1
                                radius: window.s(14)
                                property bool isActiveOp: modelData.k === "op" && calc.pendingOp === modelData.t && calc.freshEntry
                                color: {
                                    if (modelData.c === "op") return isActiveOp ? window.text : window.mauve;
                                    if (modelData.c === "fn") return window.surface2;
                                    return window.surface0;
                                }
                                opacity: kMa.containsMouse ? 0.82 : 1.0
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Text { anchors.centerIn: parent; text: modelData.t
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(22)
                                    color: modelData.c === "op" ? (parent.isActiveOp ? window.mauve : window.crust) : window.text }
                                MouseArea { id: kMa; anchors.fill: parent; hoverEnabled: true
                                    onClicked: {
                                        if (modelData.k === "d") window.calcDigit(modelData.t);
                                        else if (modelData.k === "op") window.calcOp(modelData.t);
                                        else if (modelData.k === "eq") window.calcEquals();
                                        else if (modelData.k === "clear") window.calcClear();
                                        else if (modelData.k === "neg") window.calcNeg();
                                        else if (modelData.k === "pct") window.calcPct();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
