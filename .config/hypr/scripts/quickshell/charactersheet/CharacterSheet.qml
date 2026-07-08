import QtQuick
import QtQuick.Layouts
import Quickshell
import "../"
import "LifeOsEngine.js" as Engine

// Life-OS character status window: a HEXACO personality model (6 dimensions ×
// 4 facets) rendered as a psychologically-safe RPG progression HUD, styled as
// a native part of this shell (dark matugen chrome). Mechanics live in
// LifeOsEngine.js (pure, unit-tested); this file is the view layer.
//
// Layout: a persistent LEFT character panel (the real Vitruvian Man, Leonardo
// da Vinci / public-domain, as the figure, with the HP/MP/AP/WS vital gauges
// stacked beneath it) and a RIGHT content area that switches between the MAIN
// screen (6 HEXACO dimension tiles — each showing its Level big, with a thin
// XP bar along the bottom edge) and a DETAIL page (a dimension's 4 facets +
// its active danger zones). Data input isn't wired yet — runs on
// Engine.mockState().
Item {
    id: window

    // Main.qml passes these to every widget it creates/reopens; unused here but
    // declared so the assignments don't raise "non-existent property" errors.
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
    readonly property color subtext1: _theme.subtext1
    readonly property color overlay0: _theme.overlay0
    readonly property color overlay1: _theme.overlay1
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color blue:     _theme.blue
    readonly property color green:    _theme.green
    readonly property color red:      _theme.red
    readonly property color yellow:   _theme.yellow
    readonly property color peach:    _theme.peach
    readonly property color teal:     _theme.teal

    // ── State (mock seed until a real input layer is wired) ─────────────────
    property var st: Engine.mockState()
    property bool restMode: st.isRestModeActive

    readonly property int charLevel: Engine.characterLevel(st)
    readonly property int charXp: Engine.totalXp(st)
    readonly property int charNextXp: Engine.nextLevelXp(charXp)
    readonly property real charProgress: Engine.levelProgress(charXp)
    readonly property int pendingDecay: Engine.totalPendingDecay(st)
    readonly property var dangerAll: Engine.computeDangerZones(st)

    // ── Trackers (objective proxies + lifestyle) ────────────────────────────
    readonly property var bio: st.trackers.biometrics
    readonly property var hydration: st.trackers.hydration
    readonly property var nutrition: st.trackers.nutrition
    readonly property var movement: st.trackers.movement
    readonly property string workoutFocus: Engine.workoutFocusLabel(st)
    readonly property color heartRed: "#9E2C31"
    // Veins: hidden unless the group was trained; red pump on the day, blue in
    // recovery, gone after a missed day.
    function veinColor(group) { return Engine.veinState(st, group).mode === "recovery" ? blue : heartRed; }
    function veinIntensity(group) { var v = Engine.veinState(st, group); return v.show ? v.intensity : 0; }
    readonly property int resilience: Engine.resilienceIndex(st)
    readonly property int sleepQ: Engine.sleepQuality(st)
    readonly property int stress: Engine.stressLevel(st)
    readonly property int mood: Engine.moodScore(st)
    // Adrenal colour: grey (calm) → dark red (high stress).
    readonly property color adrenalColor: {
        var t = Math.max(0, Math.min(1, stress / 100));
        return Qt.rgba(0.55 + 0.05 * t, 0.55 * (1 - t), 0.55 * (1 - t), 1.0);
    }
    readonly property string summary: Engine.lifeSummary(st)
    function stressLabel(v) { return Engine.stressLabel(v); }
    function moodLabel(v) { return Engine.moodLabel(v); }

    function dimSummary(key) { return Engine.dimensionSummary(st, key); }
    function dimDanger(key) { return Engine.dangerZonesForDim(st, key); }
    function toggleRestMode() { st.isRestModeActive = !st.isRestModeActive; restMode = st.isRestModeActive; }

    // ── Navigation ──────────────────────────────────────────────────────────
    // `view` drives the RIGHT content area (main picture+categories vs a
    // dimension's detail). `focusedVital` is independent: "" = the Life Signals
    // module shows its default readout; a vital key = that module shows the
    // vital's in-depth breakdown instead (in place, not full-screen).
    property string view: "main"        // "main" | "detail"
    property string selectedDim: "H"
    property string focusedVital: ""    // "" | "hp" | "mp" | "ap" | "ws"
    function openDim(key) { selectedDim = key; view = "detail"; }
    function openVital(key) { focusedVital = (focusedVital === key ? "" : key); }
    function clearVital() { focusedVital = ""; }
    function goBack() { view = "main"; }
    function vitalInfo(key) { return Engine.vitalInfo(key); }
    function vitalBreakdown(key) { return Engine.vitalBreakdown(st, key); }
    function accentColor(name) {
        return name === "red" ? red : name === "yellow" ? yellow
             : name === "teal" ? teal : name === "green" ? green : blue;
    }

    // ── A compact labeled bar (used for the vitals stack) ──────────────────
    Component {
        id: barComponent
        RowLayout {
            id: bar
            property string label: ""
            property real ratio: 0
            property string valueText: ""
            property color fillColor: window.blue
            spacing: s(6)
            Text {
                Layout.preferredWidth: s(36)
                text: bar.label
                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9)
                color: window.subtext0
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredWidth: s(60)
                Layout.preferredHeight: s(7)
                radius: s(3.5)
                color: window.surface1
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, bar.ratio))
                    height: parent.height; radius: parent.radius
                    color: window.restMode ? window.overlay0 : bar.fillColor
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
            }
            Text {
                Layout.preferredWidth: s(50)
                horizontalAlignment: Text.AlignRight
                text: bar.valueText
                font.family: "JetBrains Mono"; font.pixelSize: s(8.5)
                color: window.subtext0
            }
        }
    }

    // ── One HEXACO dimension as a status-bar row (main screen). Glyph + name +
    //    level, a LVL-progress bar filling the row, danger badge. Clickable →
    //    detail page. ────────────────────────────────────────────────────────
    Component {
        id: dimBarComponent
        Rectangle {
            id: drow
            property string dimKey: ""
            readonly property var summ: dimKey ? window.dimSummary(dimKey) : null
            readonly property var dz: dimKey ? window.dimDanger(dimKey) : []
            radius: s(10)
            color: hov.hovered ? window.surface1 : window.surface0
            border.color: dz.length > 0 ? window.red : (hov.hovered ? window.blue : window.surface1)
            border.width: dz.length > 0 ? 2 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
            clip: true

            HoverHandler { id: hov }
            TapHandler { onTapped: if (drow.dimKey) window.openDim(drow.dimKey) }

            RowLayout {
                anchors.fill: parent; anchors.leftMargin: s(12); anchors.rightMargin: s(12)
                anchors.topMargin: s(8); anchors.bottomMargin: s(8); spacing: s(11)

                Text {
                    text: drow.summ ? drow.summ.glyph : ""
                    font.family: "Iosevka Nerd Font"; font.pixelSize: s(18)
                    color: drow.dz.length > 0 ? window.red : window.blue
                }

                ColumnLayout {
                    Layout.preferredWidth: s(128); spacing: s(1)
                    RowLayout {
                        Layout.fillWidth: true; spacing: s(6)
                        Text {
                            Layout.fillWidth: true
                            text: drow.summ ? drow.summ.name : ""
                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(11.5)
                            color: window.text; elide: Text.ElideRight
                        }
                        Rectangle {
                            visible: drow.dz.length > 0
                            Layout.preferredHeight: s(14); Layout.preferredWidth: dzRow.implicitWidth + s(8)
                            radius: s(4)
                            color: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.2)
                            RowLayout {
                                id: dzRow
                                anchors.centerIn: parent; spacing: s(3)
                                Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(8); color: window.red }
                                Text { text: drow.dz.length; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); color: window.red }
                            }
                        }
                    }
                    Text {
                        text: drow.summ ? ("Level " + drow.summ.level) : ""
                        font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.subtext0
                    }
                }

                Loader {
                    Layout.fillWidth: true; Layout.preferredWidth: s(220)
                    sourceComponent: barComponent
                    onLoaded: {
                        item.label = "LVL";
                        item.ratio = Qt.binding(function () { return drow.summ ? drow.summ.progress : 0; });
                        item.valueText = Qt.binding(function () { return drow.summ ? ("→ Lv." + (drow.summ.level + 1)) : ""; });
                        item.fillColor = Qt.binding(function () { return drow.dz.length > 0 ? window.red : window.blue; });
                    }
                }

                Text {
                    text: ""
                    font.family: "Iosevka Nerd Font"; font.pixelSize: s(13)
                    color: hov.hovered ? window.blue : window.overlay0
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }
    }

    // ── One facet as an expanded level tile (detail page). Level is the hero,
    //    expression score top-right, thin XP bar on the bottom edge, pending-
    //    decay marker bottom-right. ───────────────────────────────────────────
    Component {
        id: facetTileComponent
        Rectangle {
            id: ftile
            property var facet: null
            readonly property real sc: facet ? facet.score : 50
            readonly property bool extreme: facet ? (sc > 85 || sc < 18) : false
            radius: s(10)
            color: window.surface0
            border.color: extreme ? window.red : window.surface1
            border.width: extreme ? 2 : 1
            clip: true

            // Top: facet name + expression score.
            RowLayout {
                anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                anchors.topMargin: s(10); anchors.leftMargin: s(11); anchors.rightMargin: s(11)
                spacing: s(6)
                Text {
                    Layout.fillWidth: true
                    text: ftile.facet ? ftile.facet.name : ""
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(10.5)
                    color: window.text; elide: Text.ElideRight
                }
                Text {
                    text: ftile.facet ? (Math.round(ftile.sc) + "/100") : ""
                    font.family: "JetBrains Mono"; font.pixelSize: s(8.5)
                    color: ftile.extreme ? window.red : window.subtext0
                }
            }

            // Centre: the Level, big.
            Column {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: s(4)
                spacing: s(-2)
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "LEVEL"
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8.5); font.letterSpacing: s(2)
                    color: window.subtext0
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: ftile.facet ? ftile.facet.level : "0"
                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: s(34)
                    color: ftile.extreme ? window.red : window.blue
                }
            }

            // Pending-decay marker (bottom-right, above the XP bar).
            Text {
                visible: ftile.facet && ftile.facet.pendingDecay > 0
                anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.rightMargin: s(11); anchors.bottomMargin: s(11)
                text: "" + (ftile.facet ? Math.round(ftile.facet.pendingDecay) : 0)
                font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.peach
            }

            // XP bar pinned to the bottom edge.
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                anchors.leftMargin: s(3); anchors.rightMargin: s(3); anchors.bottomMargin: s(3)
                height: s(4)
                radius: s(2)
                color: window.surface1
                Rectangle {
                    width: parent.width * (ftile.facet ? ftile.facet.progress : 0)
                    height: parent.height; radius: parent.radius
                    color: window.restMode ? window.overlay0 : window.green
                    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                }
            }
        }
    }

    // ── A biometric mini-stat row (label + value + optional trend arrow) ────
    Component {
        id: signalRowComponent
        RowLayout {
            id: srow
            property string label: ""
            property string value: ""
            property int trend: 0          // -1 below baseline (bad), 0 none, +1 good
            spacing: s(8)
            Text {
                Layout.preferredWidth: s(48)
                text: srow.label
                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8.5); color: window.subtext0
            }
            Text {
                Layout.fillWidth: true
                text: srow.value
                font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.text; elide: Text.ElideRight
            }
            Text {
                visible: srow.trend !== 0
                text: srow.trend < 0 ? "" : ""
                font.family: "Iosevka Nerd Font"; font.pixelSize: s(9)
                color: srow.trend < 0 ? window.red : window.green
            }
        }
    }

    // ── An organ gauge (stomach / bladder): a line-art organ that fills from
    //    the bottom up as its goal ratio rises, tinted by its tracker colour. ──
    Component {
        id: organGaugeComponent
        Canvas {
            id: organ
            property string kind: "bladder"     // "stomach" | "bladder"
            property real fillRatio: 0
            property color tint: window.blue
            onKindChanged: requestPaint()
            onFillRatioChanged: requestPaint()
            onTintChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d"); ctx.reset();
                var w = width, h = height;
                ctx.lineJoin = "round"; ctx.lineCap = "round";

                ctx.beginPath();
                if (kind === "stomach") {
                    // J-shaped pouch: fundus top-left, body, pylorus lower-right.
                    ctx.moveTo(w * 0.30, h * 0.16);
                    ctx.bezierCurveTo(w * 0.56, h * 0.00, w * 0.86, h * 0.14, w * 0.82, h * 0.44);
                    ctx.bezierCurveTo(w * 0.80, h * 0.74, w * 0.62, h * 0.96, w * 0.47, h * 0.84);
                    ctx.bezierCurveTo(w * 0.40, h * 0.78, w * 0.50, h * 0.66, w * 0.44, h * 0.56);
                    ctx.bezierCurveTo(w * 0.38, h * 0.46, w * 0.16, h * 0.48, w * 0.20, h * 0.30);
                    ctx.bezierCurveTo(w * 0.22, h * 0.22, w * 0.26, h * 0.18, w * 0.30, h * 0.16);
                } else {
                    // Bladder: rounded balloon, dome top, broader base.
                    ctx.moveTo(w * 0.50, h * 0.08);
                    ctx.bezierCurveTo(w * 0.88, h * 0.14, w * 0.98, h * 0.58, w * 0.72, h * 0.88);
                    ctx.bezierCurveTo(w * 0.58, h * 1.00, w * 0.42, h * 1.00, w * 0.28, h * 0.88);
                    ctx.bezierCurveTo(w * 0.02, h * 0.58, w * 0.12, h * 0.14, w * 0.50, h * 0.08);
                }
                ctx.closePath();

                // Fill from the bottom up to fillRatio, clipped to the organ.
                var r = Math.max(0, Math.min(1, fillRatio));
                if (r > 0) {
                    ctx.save();
                    ctx.clip();
                    ctx.globalAlpha = 0.5;
                    ctx.fillStyle = tint;
                    ctx.fillRect(0, h * (1 - r), w, h * r);
                    ctx.restore();
                }
                // Outline on top.
                ctx.globalAlpha = 0.9;
                ctx.strokeStyle = tint;
                ctx.lineWidth = Math.max(1, w * 0.05);
                ctx.stroke();
            }
        }
    }

    // ── An adrenal gland: a small cap that shifts grey → dark red with stress. ─
    Component {
        id: adrenalComponent
        Canvas {
            id: adrenal
            property color tint: "grey"
            property bool flip: false     // mirror horizontally for the other side
            onTintChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d"); ctx.reset();
                var w = width, h = height;
                if (flip) { ctx.translate(w, 0); ctx.scale(-1, 1); }
                ctx.lineJoin = "round"; ctx.lineCap = "round";
                // Triangular cap: apex up, lumpy rounded base.
                ctx.beginPath();
                ctx.moveTo(w * 0.50, h * 0.10);
                ctx.bezierCurveTo(w * 0.82, h * 0.16, w * 0.96, h * 0.52, w * 0.82, h * 0.82);
                ctx.bezierCurveTo(w * 0.70, h * 1.00, w * 0.36, h * 0.98, w * 0.22, h * 0.80);
                ctx.bezierCurveTo(w * 0.08, h * 0.56, w * 0.20, h * 0.18, w * 0.50, h * 0.10);
                ctx.closePath();
                ctx.globalAlpha = 0.9;
                ctx.fillStyle = adrenal.tint;
                ctx.fill();
                ctx.globalAlpha = 1.0;
                ctx.strokeStyle = adrenal.tint;
                ctx.lineWidth = Math.max(1, w * 0.08);
                ctx.stroke();
            }
        }
    }

    // ── Popping veins: a branching vein pattern that fades in with the amount
    //    a limb was trained today (0 = invisible). ─────────────────────────────
    Component {
        id: veinComponent
        Canvas {
            id: vein
            property real intensity: 0        // 0..1 pump level
            property color tint: window.teal
            property bool flip: false
            opacity: Math.max(0, Math.min(1, intensity))
            Behavior on opacity { NumberAnimation { duration: 300 } }
            onIntensityChanged: requestPaint()
            onTintChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d"); ctx.reset();
                var w = width, h = height;
                if (flip) { ctx.translate(w, 0); ctx.scale(-1, 1); }
                ctx.strokeStyle = tint;
                ctx.lineCap = "round"; ctx.lineJoin = "round";
                ctx.globalAlpha = 0.9;
                // Main vessel running the length of the limb.
                ctx.lineWidth = Math.max(1, w * 0.11);
                ctx.beginPath();
                ctx.moveTo(w * 0.42, h * 0.04);
                ctx.bezierCurveTo(w * 0.60, h * 0.28, w * 0.40, h * 0.52, w * 0.55, h * 0.74);
                ctx.bezierCurveTo(w * 0.62, h * 0.86, w * 0.52, h * 0.94, w * 0.48, h * 0.98);
                ctx.stroke();
                // Branches.
                ctx.lineWidth = Math.max(1, w * 0.075);
                ctx.beginPath();
                ctx.moveTo(w * 0.50, h * 0.34);
                ctx.bezierCurveTo(w * 0.70, h * 0.40, w * 0.80, h * 0.50, w * 0.86, h * 0.60);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(w * 0.45, h * 0.60);
                ctx.bezierCurveTo(w * 0.28, h * 0.66, w * 0.22, h * 0.78, w * 0.18, h * 0.90);
                ctx.stroke();
            }
        }
    }

    // ── Chrome ──────────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: s(18)
        color: window.base
        border.color: window.surface1; border.width: 1
        clip: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: s(16)
            spacing: s(10)

            // ── Header: name + overall level + XP bar + Rest Mode toggle ──
            RowLayout {
                Layout.fillWidth: true
                spacing: s(10)
                Text {
                    text: "󰙨"
                    font.family: "Iosevka Nerd Font"; font.pixelSize: s(20); color: window.blue
                }
                Text {
                    text: "HERMES"
                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: s(16); color: window.text
                }
                Text {
                    text: "LEVEL " + window.charLevel
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(14); color: window.blue
                }
                Rectangle {
                    Layout.preferredWidth: s(150); Layout.preferredHeight: s(6)
                    radius: s(3); color: window.surface1
                    Rectangle {
                        width: parent.width * window.charProgress; height: parent.height; radius: parent.radius
                        color: window.blue
                        Behavior on width { NumberAnimation { duration: 300 } }
                    }
                }
                Text {
                    text: window.charXp + " / " + window.charNextXp + " XP"
                    font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: restRow.implicitWidth + s(20); Layout.preferredHeight: s(30)
                    radius: s(8)
                    color: window.restMode ? Qt.rgba(window.peach.r, window.peach.g, window.peach.b, 0.2)
                                           : (restHov.hovered ? window.surface1 : window.surface0)
                    border.color: window.restMode ? window.peach : window.surface1; border.width: 1
                    Behavior on color { ColorAnimation { duration: 150 } }
                    HoverHandler { id: restHov }
                    TapHandler { onTapped: window.toggleRestMode() }
                    RowLayout {
                        id: restRow
                        anchors.centerIn: parent; spacing: s(5)
                        Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(12); color: window.restMode ? window.peach : window.subtext0 }
                        Text {
                            text: window.restMode ? "REST MODE" : "Rest Mode"
                            font.family: "JetBrains Mono"; font.weight: window.restMode ? Font.Bold : Font.Normal; font.pixelSize: s(10)
                            color: window.restMode ? window.peach : window.subtext0
                        }
                    }
                }
            }

            // ── Rest Mode banner ──
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: window.restMode ? s(24) : 0
                visible: window.restMode
                radius: s(8)
                color: Qt.rgba(window.peach.r, window.peach.g, window.peach.b, 0.12)
                Text {
                    anchors.centerIn: parent
                    text: "  Tavern Protocol active — all drains, penalties, decay & XP gain are frozen."
                    font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.peach
                }
            }

            // ── Body: picture + HEXACO on the LEFT, vitals + Life Signals on the
            // RIGHT. The two column blocks are declared vitals-first / picture-
            // second, but layoutDirection flips them so the wide picture+category
            // block sits left and the narrow vitals+signals block sits right.
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                layoutDirection: Qt.RightToLeft
                spacing: s(12)

                // RIGHT (declared first): vitals stack on top, then the Life
                // Signals module — which doubles as the in-depth view for
                // whichever vital is clicked.
                ColumnLayout {
                    Layout.preferredWidth: s(262)
                    Layout.fillHeight: true
                    spacing: s(10)

                    // Vital gauges: HP / MP / AP / WS. Click one → its in-depth
                    // breakdown takes over the Life Signals module below; click
                    // again (or the ✕) to return to the default readout.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: s(132)
                        radius: s(12)
                        color: window.surface0
                        border.color: window.surface1; border.width: 1
                        clip: true
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: s(8)
                            spacing: s(4)
                            Repeater {
                                model: [
                                    { key: "hp", label: "HP", accent: "red" },
                                    { key: "mp", label: "MP", accent: "blue" },
                                    { key: "ap", label: "AP", accent: "yellow" },
                                    { key: "ws", label: "WS", accent: "teal" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true; Layout.fillHeight: true
                                    radius: s(6)
                                    color: (vhov.hovered || window.focusedVital === modelData.key)
                                           ? window.surface1 : "transparent"
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    HoverHandler { id: vhov; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: window.openVital(modelData.key) }
                                    Loader {
                                        anchors.fill: parent
                                        anchors.leftMargin: s(6); anchors.rightMargin: s(6)
                                        sourceComponent: barComponent
                                        onLoaded: {
                                            item.label = Qt.binding(function () { return modelData.label; });
                                            item.fillColor = Qt.binding(function () { return window.accentColor(modelData.accent); });
                                            item.ratio = Qt.binding(function () { return window.st.vitals[modelData.key] / window.st.vitals[modelData.key + "Max"]; });
                                            item.valueText = Qt.binding(function () { return window.st.vitals[modelData.key] + "/" + window.st.vitals[modelData.key + "Max"]; });
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // LIFE SIGNALS module — its default readout, OR the focused
                    // vital's in-depth breakdown when one is selected.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: s(12)
                        color: window.surface0
                        border.color: window.surface1; border.width: 1
                        clip: true

                        // DEFAULT: objective proxies + lifestyle trackers.
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: s(12)
                            spacing: s(8)
                            visible: window.focusedVital === ""

                            // Header + Resilience Index pill.
                            RowLayout {
                                Layout.fillWidth: true; spacing: s(7)
                                Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(13); color: window.teal }
                                Text {
                                    text: "LIFE SIGNALS"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(10); font.letterSpacing: s(1.5)
                                    color: window.subtext0
                                }
                                Item { Layout.fillWidth: true }
                                Rectangle {
                                    id: resPillBg
                                    Layout.preferredHeight: s(19); Layout.preferredWidth: resPill.implicitWidth + s(14)
                                    radius: s(6)
                                    readonly property color rc: window.resilience < 55 ? window.red
                                                              : (window.resilience < 75 ? window.yellow : window.green)
                                    color: Qt.rgba(rc.r, rc.g, rc.b, 0.16)
                                    RowLayout {
                                        id: resPill
                                        anchors.centerIn: parent; spacing: s(5)
                                        Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(9); color: resPillBg.rc }
                                        Text {
                                            text: "RESILIENCE " + window.resilience
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9); color: resPillBg.rc
                                        }
                                    }
                                }
                            }

                            // Objective biometric proxies (compact for the narrow column).
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "SLEEP";
                                    item.value = Qt.binding(function () { return window.bio.sleepHours + "h · Q" + window.sleepQ + " · D" + window.bio.deepPct + " R" + window.bio.remPct; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "LATENCY";
                                    item.value = Qt.binding(function () { return window.bio.sleepLatencyMin + " min to sleep"; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "HRV";
                                    item.value = Qt.binding(function () { return window.bio.hrv + " ms (base " + window.bio.hrvBaseline + ")"; });
                                    item.trend = Qt.binding(function () { return window.bio.hrv < window.bio.hrvBaseline ? -1 : 1; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "RHR";
                                    item.value = Qt.binding(function () { return window.bio.rhr + " bpm resting"; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "DIGITAL";
                                    item.value = Qt.binding(function () { return Math.floor(window.bio.screenMin / 60) + "h" + (window.bio.screenMin % 60) + "m · " + window.bio.taskSwitches + " sw"; });
                                    item.trend = Qt.binding(function () { return window.bio.screenMin > 300 ? -1 : 1; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "WORKOUT";
                                    item.value = Qt.binding(function () { return window.movement.workouts + " · " + window.workoutFocus + " · " + (Math.round(window.movement.steps / 100) / 10) + "k steps"; });
                                    item.trend = Qt.binding(function () { return window.movement.workouts >= window.movement.workoutTarget ? 1 : 0; });
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 1
                                Layout.topMargin: s(3); Layout.bottomMargin: s(1)
                                color: window.surface1
                            }

                            // Lifestyle trackers.
                            Loader {
                                Layout.fillWidth: true; sourceComponent: barComponent
                                onLoaded: {
                                    item.label = "H₂O"; item.fillColor = window.blue;
                                    item.ratio = Qt.binding(function () { return window.hydration.cups / window.hydration.target; });
                                    item.valueText = Qt.binding(function () { return window.hydration.cups + "/" + window.hydration.target + " cups"; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: barComponent
                                onLoaded: {
                                    item.label = "FOOD"; item.fillColor = window.peach;
                                    item.ratio = Qt.binding(function () { return window.nutrition.meals / window.nutrition.mealTarget; });
                                    item.valueText = Qt.binding(function () { return window.nutrition.meals + "/" + window.nutrition.mealTarget + " · Q" + window.nutrition.quality; });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: barComponent
                                onLoaded: {
                                    item.label = "STRESS";
                                    item.ratio = Qt.binding(function () { return window.stress / 100; });
                                    item.valueText = Qt.binding(function () { return window.stressLabel(window.stress); });
                                    item.fillColor = Qt.binding(function () { return window.stress > 65 ? window.red : (window.stress > 35 ? window.yellow : window.green); });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: barComponent
                                onLoaded: {
                                    item.label = "MOOD";
                                    item.ratio = Qt.binding(function () { return window.mood / 100; });
                                    item.valueText = Qt.binding(function () { return window.moodLabel(window.mood); });
                                    item.fillColor = Qt.binding(function () { return window.mood < 40 ? window.red : (window.mood < 65 ? window.yellow : window.green); });
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 1
                                Layout.topMargin: s(4); Layout.bottomMargin: s(2)
                                color: window.surface1
                            }
                            Text {
                                text: "SUMMARY"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: window.summary
                                font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.subtext1
                                wrapMode: Text.Wrap; lineHeight: 1.2
                            }
                            Item { Layout.fillHeight: true }
                        }

                        // FOCUSED: the clicked vital's in-depth breakdown, in place.
                        ColumnLayout {
                            id: vitalFocus
                            anchors.fill: parent
                            anchors.margins: s(12)
                            spacing: s(9)
                            visible: window.focusedVital !== ""
                            readonly property var info: window.focusedVital !== "" ? window.vitalInfo(window.focusedVital) : null
                            readonly property var breakdown: window.focusedVital !== "" ? window.vitalBreakdown(window.focusedVital) : []
                            readonly property color accent: info ? window.accentColor(info.accent) : window.blue
                            readonly property int cur: info ? window.st.vitals[info.key] : 0
                            readonly property int max: info ? window.st.vitals[info.key + "Max"] : 100

                            // Header: title + close.
                            RowLayout {
                                Layout.fillWidth: true; spacing: s(6)
                                Text {
                                    Layout.fillWidth: true
                                    text: vitalFocus.info ? (vitalFocus.info.name + "  (" + vitalFocus.info.label + ")") : ""
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(12); color: window.text
                                    elide: Text.ElideRight
                                }
                                Rectangle {
                                    Layout.preferredWidth: s(20); Layout.preferredHeight: s(20); radius: s(6)
                                    color: closeHov.hovered ? window.surface1 : "transparent"
                                    HoverHandler { id: closeHov; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: window.clearVital() }
                                    Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(11); color: window.subtext0 }
                                }
                            }

                            // Gauge: big value + bar.
                            RowLayout {
                                Layout.fillWidth: true; spacing: s(5)
                                Text {
                                    text: vitalFocus.cur
                                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: s(34); color: vitalFocus.accent
                                }
                                Text {
                                    Layout.alignment: Qt.AlignBottom; Layout.bottomMargin: s(6)
                                    text: "/ " + vitalFocus.max
                                    font.family: "JetBrains Mono"; font.pixelSize: s(12); color: window.subtext0
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    Layout.alignment: Qt.AlignBottom; Layout.bottomMargin: s(6)
                                    text: Math.round(vitalFocus.max > 0 ? vitalFocus.cur / vitalFocus.max * 100 : 0) + "%"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(12); color: window.subtext1
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: s(10)
                                radius: s(5); color: window.surface1
                                Rectangle {
                                    width: parent.width * Math.max(0, Math.min(1, vitalFocus.max > 0 ? vitalFocus.cur / vitalFocus.max : 0))
                                    height: parent.height; radius: parent.radius
                                    color: window.restMode ? window.overlay0 : vitalFocus.accent
                                    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: vitalFocus.info ? vitalFocus.info.tagline : ""
                                font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.subtext1; wrapMode: Text.Wrap
                            }

                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 1
                                Layout.topMargin: s(2); Layout.bottomMargin: s(1)
                                color: window.surface1
                            }

                            Text {
                                text: "CONTRIBUTING INPUTS"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                            }
                            Repeater {
                                model: vitalFocus.breakdown
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: s(7)
                                    Text {
                                        Layout.preferredWidth: s(70)
                                        text: modelData.label
                                        font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.text; elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: s(8)
                                        radius: s(4); color: window.surface1
                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(1, modelData.ratio))
                                            height: parent.height; radius: parent.radius
                                            color: window.restMode ? window.overlay0 : vitalFocus.accent
                                            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                        }
                                    }
                                    Text {
                                        Layout.preferredWidth: s(64); horizontalAlignment: Text.AlignRight
                                        text: modelData.valueText
                                        font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                                    }
                                }
                            }
                            Item { Layout.fillHeight: true }
                        }
                    }
                }

                // LEFT (declared second; RightToLeft puts it on the left): the
                // picture + HEXACO categories, OR a dimension's detail page.
                // preferredWidth is REQUIRED alongside fillWidth here — fillWidth
                // alone collapses this to zero in this environment (documented
                // layout gotcha), handing the whole body width to the other panel.
                Item {
                    Layout.preferredWidth: s(485)
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // MAIN VIEW — the Vitruvian figure at the top-right, with the
                    // 6 HEXACO personality categories as status bars below it.
                    ColumnLayout {
                        anchors.fill: parent
                        visible: window.view === "main"
                        spacing: s(8)

                        // Picture, top-right.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: s(12)
                            color: window.surface0
                            border.color: window.surface1; border.width: 1
                            clip: true

                            // Beating heart behind the chest. Declared BEFORE the
                            // Image so it sits behind the outline's chest lines;
                            // positioned relative to the painted figure and pulsed
                            // once per beat at the tracked resting heart rate.
                            Item {
                                id: heartbeat
                                readonly property real beatMs: 60000 / Math.max(30, window.bio.rhr)
                                // Over the body's LEFT chest — the figure faces us,
                                // so that's the viewer's right of the sternum.
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: vitImg.paintedHeight * 0.02
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.13
                                height: Math.max(1, vitImg.paintedHeight * 0.06)
                                width: height * (629 / 850)
                                transformOrigin: Item.Center
                                opacity: window.restMode ? 0.25 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }

                                Image {
                                    anchors.fill: parent
                                    source: "anatomical_heart.png"
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true; asynchronous: true
                                    opacity: 0.9
                                    // Native 629×850 decoded to a ~2MB texture for a
                                    // ~25px sprite; decode at 5x the display size instead.
                                    sourceSize.width: 118; sourceSize.height: 160
                                }

                                // lub-dub, then rest until the next beat. Timer-stepped
                                // with the exact piecewise OutQuad/InQuad curve the old
                                // SequentialAnimation produced: the old animation kept
                                // the render loop at full frame rate even through its
                                // between-beat pause, and ran while the widget sat
                                // hidden in Main.qml's cache (no visibility gate).
                                // During the rest phase the guard writes nothing, so
                                // the scene goes fully idle between beats.
                                Timer {
                                    interval: 16; repeat: true
                                    running: window.visible && !window.restMode
                                    onTriggered: {
                                        var P = Math.max(550, heartbeat.beatMs);
                                        var t = Date.now() % P;
                                        var v;
                                        if (t < 90)       { var x = t / 90;          v = 1.00 + 0.30 * (x * (2 - x)); }
                                        else if (t < 200) { var x = (t - 90) / 110;  v = 1.30 - 0.22 * x * x; }
                                        else if (t < 280) { var x = (t - 200) / 80;  v = 1.08 + 0.12 * (x * (2 - x)); }
                                        else if (t < 430) { var x = (t - 280) / 150; v = 1.20 - 0.20 * x * x; }
                                        else v = 1.0;
                                        if (v !== heartbeat.scale) heartbeat.scale = v;
                                    }
                                }
                            }

                            // Stomach — upper-left abdomen (person's left = viewer's
                            // right, just above the navel); fills with the food goal.
                            Loader {
                                sourceComponent: organGaugeComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: vitImg.paintedHeight * 0.03
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.065
                                width: Math.max(1, vitImg.paintedHeight * 0.09)
                                height: Math.max(1, vitImg.paintedHeight * 0.075)
                                opacity: window.restMode ? 0.3 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }
                                onLoaded: {
                                    item.kind = "stomach";
                                    item.tint = Qt.binding(function () { return window.peach; });
                                    item.fillRatio = Qt.binding(function () { return window.nutrition.meals / window.nutrition.mealTarget; });
                                }
                            }

                            // Bladder — lower pelvis (midline, below the navel);
                            // fills with the water goal.
                            Loader {
                                sourceComponent: organGaugeComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: vitImg.paintedHeight * 0.01625
                                width: Math.max(1, vitImg.paintedHeight * 0.08)
                                height: Math.max(1, vitImg.paintedHeight * 0.075)
                                opacity: window.restMode ? 0.3 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }
                                onLoaded: {
                                    item.kind = "bladder";
                                    item.tint = Qt.binding(function () { return window.blue; });
                                    item.fillRatio = Qt.binding(function () { return window.hydration.cups / window.hydration.target; });
                                }
                            }

                            // Adrenal glands — one either side, just at the top of
                            // the bladder; grey when calm, dark red under stress.
                            Loader {
                                sourceComponent: adrenalComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: -vitImg.paintedHeight * 0.038
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.02
                                width: Math.max(1, vitImg.paintedHeight * 0.024)
                                height: Math.max(1, vitImg.paintedHeight * 0.021)
                                opacity: window.restMode ? 0.3 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }
                                onLoaded: {
                                    item.flip = true;
                                    item.tint = Qt.binding(function () { return window.adrenalColor; });
                                }
                            }
                            Loader {
                                sourceComponent: adrenalComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: vitImg.paintedHeight * 0.038
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.02
                                width: Math.max(1, vitImg.paintedHeight * 0.024)
                                height: Math.max(1, vitImg.paintedHeight * 0.021)
                                opacity: window.restMode ? 0.3 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }
                                onLoaded: {
                                    item.tint = Qt.binding(function () { return window.adrenalColor; });
                                }
                            }

                            // Popping veins — biceps (both upper arms) show with arm
                            // training, thighs with leg training, fading in by how much
                            // each group was worked today.
                            Loader {   // left bicep
                                sourceComponent: veinComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: -vitImg.paintedHeight * 0.12
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.15
                                width: Math.max(1, vitImg.paintedHeight * 0.065)
                                height: Math.max(1, vitImg.paintedHeight * 0.078)
                                rotation: 100
                                onLoaded: { item.flip = true; item.tint = Qt.binding(function () { return window.veinColor("arms"); }); item.intensity = Qt.binding(function () { return window.veinIntensity("arms"); }); }
                            }
                            Loader {   // right bicep
                                sourceComponent: veinComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: vitImg.paintedHeight * 0.12
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.15
                                width: Math.max(1, vitImg.paintedHeight * 0.065)
                                height: Math.max(1, vitImg.paintedHeight * 0.078)
                                rotation: -100
                                onLoaded: { item.tint = Qt.binding(function () { return window.veinColor("arms"); }); item.intensity = Qt.binding(function () { return window.veinIntensity("arms"); }); }
                            }
                            Loader {   // left thigh
                                sourceComponent: veinComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: -vitImg.paintedHeight * 0.04
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: vitImg.paintedHeight * 0.145
                                width: Math.max(1, vitImg.paintedHeight * 0.042)
                                height: Math.max(1, vitImg.paintedHeight * 0.11)
                                onLoaded: { item.flip = true; item.tint = Qt.binding(function () { return window.veinColor("legs"); }); item.intensity = Qt.binding(function () { return window.veinIntensity("legs"); }); }
                            }
                            Loader {   // right thigh
                                sourceComponent: veinComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.horizontalCenterOffset: vitImg.paintedHeight * 0.04
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: vitImg.paintedHeight * 0.145
                                width: Math.max(1, vitImg.paintedHeight * 0.042)
                                height: Math.max(1, vitImg.paintedHeight * 0.11)
                                onLoaded: { item.tint = Qt.binding(function () { return window.veinColor("legs"); }); item.intensity = Qt.binding(function () { return window.veinIntensity("legs"); }); }
                            }

                            Image {
                                id: vitImg
                                anchors.fill: parent; anchors.margins: s(12)
                                source: "vitruvian_outline.png"
                                // ~2x the painted size — same on-screen result, half
                                // the decoded texture memory (958×966 native).
                                sourceSize.width: 640; sourceSize.height: 645
                                fillMode: Image.PreserveAspectFit; smooth: true; asynchronous: true
                                horizontalAlignment: Image.AlignHCenter; verticalAlignment: Image.AlignVCenter
                                opacity: window.restMode ? 0.35 : 0.9
                                Behavior on opacity { NumberAnimation { duration: 250 } }
                            }
                        }

                        // Personality categories, moved down below the picture.
                        Repeater {
                            model: ["H", "E", "X", "A", "C", "O"]
                            delegate: Loader {
                                required property var modelData
                                Layout.fillWidth: true; Layout.preferredHeight: s(48)
                                sourceComponent: dimBarComponent
                                onLoaded: item.dimKey = modelData
                            }
                        }
                    }

                    // DETAIL VIEW — one dimension's facets + danger zones.
                    ColumnLayout {
                        id: detailView
                        anchors.fill: parent
                        visible: window.view === "detail"
                        spacing: s(10)
                        readonly property var summ: window.view === "detail" ? window.dimSummary(window.selectedDim) : null
                        readonly property var dz: window.view === "detail" ? window.dimDanger(window.selectedDim) : []

                        RowLayout {
                            Layout.fillWidth: true; spacing: s(10)
                            Rectangle {
                                Layout.preferredWidth: s(64); Layout.preferredHeight: s(26); radius: s(7)
                                color: backHov.hovered ? window.surface1 : window.surface0
                                border.color: window.surface1; border.width: 1
                                HoverHandler { id: backHov }
                                TapHandler { onTapped: window.goBack() }
                                RowLayout {
                                    anchors.centerIn: parent; spacing: s(4)
                                    Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(11); color: window.subtext0 }
                                    Text { text: "Back"; font.family: "JetBrains Mono"; font.pixelSize: s(10); color: window.subtext0 }
                                }
                            }
                            Text {
                                text: detailView.summ ? detailView.summ.glyph + "  " + detailView.summ.name : ""
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(14); color: window.text
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: detailView.summ ? "Lv." + detailView.summ.level : ""
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(14); color: window.blue
                            }
                        }

                        // Facets as expanded level tiles, 2 cols × 2 rows.
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.fillHeight: true; spacing: s(10)
                            RowLayout {
                                Layout.fillWidth: true; Layout.fillHeight: true; spacing: s(10)
                                Loader {
                                    Layout.fillWidth: true; Layout.preferredWidth: s(260); Layout.fillHeight: true
                                    sourceComponent: facetTileComponent
                                    onLoaded: item.facet = Qt.binding(function () { return detailView.summ ? detailView.summ.facets[0] : null; })
                                }
                                Loader {
                                    Layout.fillWidth: true; Layout.preferredWidth: s(260); Layout.fillHeight: true
                                    sourceComponent: facetTileComponent
                                    onLoaded: item.facet = Qt.binding(function () { return detailView.summ ? detailView.summ.facets[1] : null; })
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.fillHeight: true; spacing: s(10)
                                Loader {
                                    Layout.fillWidth: true; Layout.preferredWidth: s(260); Layout.fillHeight: true
                                    sourceComponent: facetTileComponent
                                    onLoaded: item.facet = Qt.binding(function () { return detailView.summ ? detailView.summ.facets[2] : null; })
                                }
                                Loader {
                                    Layout.fillWidth: true; Layout.preferredWidth: s(260); Layout.fillHeight: true
                                    sourceComponent: facetTileComponent
                                    onLoaded: item.facet = Qt.binding(function () { return detailView.summ ? detailView.summ.facets[3] : null; })
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true; spacing: s(6)
                            visible: detailView.dz.length > 0
                            Text {
                                text: "  DANGER ZONES"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(10); color: window.red
                            }
                            Repeater {
                                model: detailView.dz
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: dzText.implicitHeight + s(16)
                                    radius: s(8)
                                    color: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.1)
                                    border.color: Qt.rgba(window.red.r, window.red.g, window.red.b, 0.4); border.width: 1
                                    ColumnLayout {
                                        id: dzText
                                        anchors.left: parent.left; anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter; anchors.margins: s(10)
                                        spacing: s(2)
                                        Text {
                                            text: modelData.name
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(10); color: window.red
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.desc
                                            font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.subtext1; wrapMode: Text.Wrap
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Footer ──
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: window.dangerAll.length > 0
                        ? ("  " + window.dangerAll.length + " danger zone" + (window.dangerAll.length === 1 ? "" : "s") + " active")
                        : "  no danger zones"
                    font.family: "JetBrains Mono"; font.pixelSize: s(9)
                    color: window.dangerAll.length > 0 ? window.red : window.overlay0
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: window.pendingDecay > 0
                        ? ("" + Math.round(window.pendingDecay) + " XP queued → applies at next check-in")
                        : "no decay pending"
                    font.family: "JetBrains Mono"; font.pixelSize: s(9)
                    color: window.pendingDecay > 0 ? window.peach : window.overlay0
                }
            }
        }
    }

    // ── Intro (matches this shell's other popups' open animation) ──────────
    property real introMain: 0
    NumberAnimation on introMain { from: 0; to: 1.0; duration: 450; easing.type: Easing.OutCubic }
    opacity: introMain
    scale: 0.97 + 0.03 * introMain
}
