import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../"
import "LifeOsEngine.js" as Engine

// Life-OS character status window: a HEXACO personality model (6 dimensions ×
// 4 facets) rendered as a psychologically-safe RPG progression HUD, styled as
// a native part of this shell (dark matugen chrome). Mechanics live in
// LifeOsEngine.js (pure, unit-tested); this file is the view layer.
//
// Layout: a persistent LEFT character panel (the real Vitruvian Man, Leonardo
// da Vinci / public-domain, as the figure, with the HP/MP/AP/EP/SP/WS vital gauges
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
    readonly property color mauve:    _theme.mauve
    // Not from the theme on purpose: the "steps goal met" reward state should
    // read as metallic gold whatever palette matugen is in.
    readonly property color gold:     "#e8c34a"
    // Macro pie slices: three distinct matugen-palette accents (mauve / teal /
    // yellow) — well-separated hues that track the wallpaper theme.
    readonly property color macroProtein: _theme.mauve
    readonly property color macroCarb:    _theme.teal
    readonly property color macroFat:     _theme.yellow

    // ── State (mock seed until a real input layer is wired) ─────────────────
    property var st: Engine.mockState()
    property bool restMode: st.isRestModeActive

    // First LIVE input: today's high temp + humidity from the calendar widget's
    // weather cache feed the water-target math (Engine.dailyWaterTarget → mpMax).
    // Same FileView pattern as MatugenStore — no subprocess, no polling.
    FileView {
        path: Quickshell.env("HOME") + "/.cache/quickshell/weather/weather.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: window._applyWeather(text())
    }
    function _applyWeather(raw) {
        try {
            var w = JSON.parse(raw);
            var today = (w.forecast && w.forecast.length) ? w.forecast[0] : null;
            if (!today) return;
            st.trackers.environment.tempC = parseFloat(today.max);
            st.trackers.environment.humidity = parseFloat(today.humidity);
            Engine.syncVitalsFromTrackers(st);
            st = st;   // var mutation doesn't notify — reassign to re-run bindings
        } catch (e) { /* stale/partial cache write — keep last values */ }
    }

    // Allostatic-load biomarkers: user-supplied blood-panel + home measurements
    // (labs.json next to this file). Only what's filled in gets scored; the
    // engine reports its own coverage.
    FileView {
        path: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/charactersheet/labs.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: window._applyLabs(text())
    }
    function _applyLabs(raw) {
        try {
            var j = JSON.parse(raw);
            var labs = {};
            for (var k in j) {
                if (k.indexOf("_") === 0) continue;          // skip _README
                var e = j[k];
                if (!e || e.value === null || e.value === undefined) continue;
                // labs.json carries human dates (YYYY-MM-DD); the engine wants epoch seconds.
                var epoch = e.date ? Date.parse(e.date + "T12:00:00") / 1000 : 0;
                labs[k] = { value: Number(e.value), date: epoch };
            }
            st.trackers.labs = labs;
            st = st;
        } catch (e) { /* malformed edit in progress — keep last good labs */ }
    }
    // PSS-10 quarterly check-in (pss.json). Subjective perceived stress — the
    // companion to the objective allostatic index.
    FileView {
        path: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/charactersheet/pss.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: window._applyPss(text())
    }
    function _applyPss(raw) {
        try {
            var j = JSON.parse(raw);
            var score = Engine.scorePss10(j.answers);
            var epoch = j.date ? Date.parse(j.date + "T12:00:00") / 1000 : 0;
            st.trackers.pss = { score: score, date: epoch };
            st = st;
        } catch (e) { /* mid-edit — keep last good answers */ }
    }
    // TODAY'S DAY LOG (daylog.json) — every stat, not just food. Same schema as the
    // archived days in history/day-<date>.json, so there is ONE format everywhere:
    // at end of day the pipeline copies this file into history/ and starts a fresh one.
    property var pendingFood: []
    FileView {
        path: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/charactersheet/daylog.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: window._applyDayLog(text())
    }
    // Tracker groups the log may carry. Each is MERGED key-by-key, so a partial
    // group (e.g. only `steps`) leaves the rest of that group alone.
    readonly property var _trackerGroups: ["nutrition", "intake", "movement",
                                           "biometrics", "environment", "affect", "sleep"]
    function _applyDayLog(raw) {
        try {
            var j = JSON.parse(raw);
            // apply ONLY today's log — a stale file is ignored (the day resets on its own)
            var d = new Date();
            var today = d.getFullYear() + "-"
                      + String(d.getMonth() + 1).padStart(2, "0") + "-"
                      + String(d.getDate()).padStart(2, "0");
            if (j.date !== today) { window.pendingFood = []; return; }

            // accept the nested `trackers` block, or the same groups at the top level
            var src = j.trackers || j;
            for (var i = 0; i < _trackerGroups.length; i++) {
                var g = _trackerGroups[i];
                if (!src[g]) continue;
                if (!st.trackers[g]) st.trackers[g] = {};
                for (var k in src[g]) st.trackers[g][k] = src[g][k];
            }
            // medication doses → the PP potions (see POTION_DEFS in the engine)
            if (src.meds) st.trackers.meds = src.meds;
            if (j.mealLog) st.mealLog = j.mealLog;
            window.pendingFood = j.pending || [];

            Engine.syncVitalsFromTrackers(st);
            // A shallow clone forces a NEW top-level reference so QML actually
            // re-runs the bindings — `st = st` (same reference) can be optimised
            // away and silently not notify.
            st = Object.assign({}, st);
        } catch (e) { /* mid-write — keep last good log */ }
    }
    readonly property var allostatic: Engine.allostaticLoad(st)
    readonly property var pss: Engine.pssStatus(st)
    readonly property var affect: Engine.affectState(st)   // Russell circumplex point

    readonly property int charLevel: Engine.characterLevel(st)
    readonly property int charXp: Engine.totalXp(st)
    readonly property int charNextXp: Engine.nextLevelXp(charXp)
    readonly property real charProgress: Engine.levelProgress(charXp)
    readonly property int pendingDecay: Engine.totalPendingDecay(st)
    readonly property var dangerAll: Engine.computeDangerZones(st)

    // ── Trackers (objective proxies + lifestyle) ────────────────────────────
    readonly property var bio: st.trackers.biometrics
    readonly property var intake: st.trackers.intake   // today's drinks, as active compounds
    readonly property var nutrition: st.trackers.nutrition
    readonly property var movement: st.trackers.movement
    readonly property var mealLog: st.mealLog || {}   // per-meal Breakfast/Lunch/Dinner log
    // Character name = the actual login user (falls back to PLAYER).
    readonly property string userName: (Quickshell.env("USER") || "PLAYER").toUpperCase()
    readonly property color heartRed: "#9f2126"   // sampled from anatomical_heart.png; vessels + heart share it
    readonly property int resilience: Engine.resilienceIndex(st)
    readonly property bool apGold: Engine.stepsGoalMet(st)   // steps goal met → AP renders gold
    readonly property int sleepQ: Engine.sleepQuality(st)
    readonly property int stress: Engine.stressLevel(st)
    readonly property int energy: Engine.energyLevel(st)   // EP: activation × bodily resources
    readonly property string summary: Engine.lifeSummary(st)

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
    property string focusedVital: ""    // "" | "hp" | "pp" | "ap" | "mp" | "ep" | "sp" | "fp"
    function openDim(key) { selectedDim = key; view = "detail"; }
    function openVital(key) { focusedVital = (focusedVital === key ? "" : key); }
    function clearVital() { focusedVital = ""; }
    function goBack() { view = "main"; }
    function vitalInfo(key) { return Engine.vitalInfo(key); }
    function vitalBreakdown(key) { return Engine.vitalBreakdown(dayState || st, key); }

    // ── DAY NAVIGATION (every vital page) ───────────────────────────────────
    // 0 = today, -1 = yesterday, … Past days are rebuilt from the history folder;
    // today comes from the live trackers. You can't go into the future.
    property int foodDayOffset: 0
    property bool calendarOpen: false
    // month the calendar grid is showing (independent of the selected day)
    property int calYear: new Date().getFullYear()
    property int calMonth: new Date().getMonth()      // 0–11
    readonly property var monthNames: ["January", "February", "March", "April", "May", "June",
                                       "July", "August", "September", "October", "November", "December"]
    function calShift(delta) {
        var m = calMonth + delta, y = calYear;
        while (m < 0)  { m += 12; y -= 1; }
        while (m > 11) { m -= 12; y += 1; }
        calMonth = m; calYear = y;
    }
    // The grid cells for calYear/calMonth: leading blanks (d === 0) then each day,
    // tagged with its offset from today (future days aren't selectable).
    function calDays() {
        var out = [];
        var startDow = new Date(calYear, calMonth, 1).getDay();
        var daysIn = new Date(calYear, calMonth + 1, 0).getDate();
        for (var i = 0; i < startDow; i++) out.push({ d: 0, off: 0, future: false });
        for (var d = 1; d <= daysIn; d++) {
            var off = offsetForDate(calYear, calMonth, d);
            out.push({ d: d, off: off, future: off > 0 });
        }
        return out;
    }
    function _pad2(n) { return String(n).padStart(2, "0"); }
    function isoForOffset(off) {
        var d = new Date();
        d.setDate(d.getDate() + off);
        return d.getFullYear() + "-" + _pad2(d.getMonth() + 1) + "-" + _pad2(d.getDate());
    }
    // offset (≤0) for a given Y/M/D, or 1 if it's in the future (not selectable)
    function offsetForDate(y, m, d) {
        var t = new Date(); t.setHours(12, 0, 0, 0);
        var x = new Date(y, m, d, 12, 0, 0, 0);
        return Math.round((x - t) / 86400000);
    }
    readonly property string foodDayIso: isoForOffset(foodDayOffset)
    readonly property string foodDayLabel: foodDayOffset === 0 ? "Today"
                                         : foodDayOffset === -1 ? "Yesterday"
                                         : foodDayIso
    // A past day's archive, loaded on demand. null when the day has no file.
    property var histLog: null
    FileView {
        id: histView
        path: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/charactersheet/history/day-"
              + window.foodDayIso + ".json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { window.histLog = JSON.parse(text()); }
            catch (e) { window.histLog = null; }
        }
        onLoadFailed: window.histLog = null
    }

    // The STATE every detail page renders: today = the live trackers; a past day =
    // rebuilt from its archive. null when that day was never logged.
    readonly property var dayState: {
        if (foodDayOffset === 0) return st;
        if (!histLog) return null;
        return _rebuildDay(histLog);
    }
    readonly property bool dayHas: foodDayOffset === 0 || histLog !== null

    // ── THE WEEK BEFORE the selected day (EP's 7-night sleep-quality graph) ──
    // Seven more FileViews, one per prior day, each rebuilt through the same
    // _rebuildDay() path so a night's score here is computed exactly the way the
    // big gauge computes it. A day with no archive simply has no bar.
    property var weekRaw: [null, null, null, null, null, null, null]
    function _setWeekDay(i, raw) {
        var arr = weekRaw.slice();          // new reference so the binding re-runs
        try { arr[i] = raw ? JSON.parse(raw) : null; }
        catch (e) { arr[i] = null; }
        weekRaw = arr;
    }
    function _dayLetter(off) {
        var d = new Date();
        d.setDate(d.getDate() + off);
        return ["S", "M", "T", "W", "T", "F", "S"][d.getDay()];
    }
    Item {
        visible: false
        Repeater {
            // Only mount the seven history FileViews while the EP page is actually
            // open. Otherwise this is 7 inotify watches + 7 JSON reads + 7 full
            // day-rebuilds kept alive for a graph nobody is looking at.
            model: (window.visible && window.focusedVital === "ep") ? 7 : 0
            delegate: Item {
                id: weekCell
                required property int index
                readonly property int off: window.foodDayOffset - (index + 1)
                FileView {
                    path: Quickshell.env("HOME")
                          + "/.config/hypr/scripts/quickshell/charactersheet/history/day-"
                          + window.isoForOffset(weekCell.off) + ".json"
                    watchChanges: true
                    onFileChanged: reload()
                    onLoaded: window._setWeekDay(weekCell.index, text())
                    onLoadFailed: window._setWeekDay(weekCell.index, null)
                }
            }
        }
    }
    // oldest → newest, so the graph reads left-to-right into the selected day.
    // Each night carries its ARCHITECTURE (deep / core / rem minutes) so the bar can
    // be stacked, not just a single block.
    readonly property var weekSleep: {
        var out = [];
        for (var i = 6; i >= 0; i--) {
            var off = foodDayOffset - (i + 1);
            var j = weekRaw[i];
            var e = { off: off, letter: _dayLetter(off), q: 0, has: !!j,
                      deep: 0, core: 0, rem: 0, asleep: 0 };
            if (j) {
                try {
                    var ps = _rebuildDay(j);
                    e.q = Engine.sleepQuality(ps);
                    var ss = Engine.sleepSession(ps);
                    if (ss) {
                        e.deep   = ss.stages[0].min;   // stages: deep, rem, core, awake
                        e.rem    = ss.stages[1].min;
                        e.core   = ss.stages[2].min;
                        e.asleep = ss.asleepMin;
                    }
                } catch (err) { /* corrupt archive — leave the night blank */ }
            }
            out.push(e);
        }
        return out;
    }
    readonly property int weekSleepAvg: {
        var sum = 0, n = 0;
        for (var i = 0; i < weekSleep.length; i++)
            if (weekSleep[i].has) { sum += weekSleep[i].q; n++; }
        return n > 0 ? Math.round(sum / n) : 0;
    }
    // Bar scale: 8 h fills the bar, but a longer night still fits.
    readonly property int weekSleepScale: {
        var mx = 480;
        for (var i = 0; i < weekSleep.length; i++)
            if (weekSleep[i].asleep > mx) mx = weekSleep[i].asleep;
        return mx;
    }

    // Rebuild a past day from its archive. Deliberately starts from an EMPTY state,
    // NOT from today's — so any tracker the archive doesn't carry reads as empty
    // rather than silently showing today's numbers under a past date.
    function _rebuildDay(j) {
        var ps = Engine.emptyState();
        var k;
        if (j.trackers)  for (k in j.trackers)  ps.trackers[k] = j.trackers[k];
        if (j.nutrition) for (k in j.nutrition) ps.trackers.nutrition[k] = j.nutrition[k];
        if (j.intake)    for (k in j.intake)    ps.trackers.intake[k] = j.intake[k];
        if (j.meds)      ps.trackers.meds = j.meds;
        if (j.facets)    ps.facets = j.facets;
        if (j.fpEarnedToday !== undefined) ps.fpEarnedToday = j.fpEarnedToday;
        ps.mealLog = j.mealLog || {};
        Engine.syncVitalsFromTrackers(ps);
        return ps;
    }
    function accentColor(name) {
        return name === "red" ? red : name === "yellow" ? yellow
             : name === "teal" ? teal : name === "green" ? green
             : name === "peach" ? peach : name === "mauve" ? mauve : blue;
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
                textFormat: Text.PlainText
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
                color: window.surface1; clip: true
                readonly property color acc: window.restMode ? window.overlay0 : bar.fillColor
                // base fill (0–100%)
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, bar.ratio))
                    height: parent.height; radius: parent.radius
                    color: parent.acc
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
                // OVERFLOW: counters that tick past their target lap again in a
                // lighter shade of the same colour.
                Rectangle {
                    visible: bar.ratio > 1
                    width: parent.width * Math.min(1, bar.ratio - 1)
                    height: parent.height; radius: parent.radius
                    color: Qt.lighter(parent.acc, 1.5)
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
            }
            Text {
                textFormat: Text.PlainText
                Layout.preferredWidth: s(58)   // wide enough for "1450/2687" (HP is kcal-denominated)
                horizontalAlignment: Text.AlignRight
                text: bar.valueText
                font.family: "JetBrains Mono"; font.pixelSize: s(8.5)
                color: window.subtext0
            }
        }
    }

    // ── One clickable vital row (the HP/PP/AP/EP/SP/MP/FP stack). Shared by the
    //    two Repeaters that sit either side of the EP│SP divider. ────────────
    Component {
        id: vitalRowComponent
        Rectangle {
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
                    item.fillColor = Qt.binding(function () {
                        return (modelData.key === "ap" && window.apGold)
                               ? window.gold : window.accentColor(modelData.accent);
                    });
                    item.ratio = Qt.binding(function () { return window.st.vitals[modelData.key] / window.st.vitals[modelData.key + "Max"]; });
                    item.valueText = Qt.binding(function () { return window.st.vitals[modelData.key] + "/" + window.st.vitals[modelData.key + "Max"]; });
                }
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
                    textFormat: Text.PlainText
                    text: drow.summ ? drow.summ.glyph : ""
                    font.family: "Iosevka Nerd Font"; font.pixelSize: s(18)
                    color: drow.dz.length > 0 ? window.red : window.blue
                }

                ColumnLayout {
                    Layout.preferredWidth: s(128); spacing: s(1)
                    RowLayout {
                        Layout.fillWidth: true; spacing: s(6)
                        Text {
                            textFormat: Text.PlainText
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
                                Text { textFormat: Text.PlainText; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(8); color: window.red }
                                Text { textFormat: Text.PlainText; text: drow.dz.length; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); color: window.red }
                            }
                        }
                    }
                    Text {
                        textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: ftile.facet ? ftile.facet.name : ""
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(10.5)
                    color: window.text; elide: Text.ElideRight
                }
                Text {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "LEVEL"
                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8.5); font.letterSpacing: s(2)
                    color: window.subtext0
                }
                Text {
                    textFormat: Text.PlainText
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: ftile.facet ? ftile.facet.level : "0"
                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: s(34)
                    color: ftile.extreme ? window.red : window.blue
                }
            }

            // Pending-decay marker (bottom-right, above the XP bar).
            Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.preferredWidth: s(48)
                text: srow.label
                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8.5); color: window.subtext0
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: srow.value
                font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.text; elide: Text.ElideRight
            }
            Text {
                textFormat: Text.PlainText
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
            property color bg: window.surface0   // opaque backdrop = the picture card
            onKindChanged: requestPaint()
            onFillRatioChanged: requestPaint()
            onTintChanged: requestPaint()
            onBgChanged: requestPaint()
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

                // Opaque backdrop: occlude whatever sits behind the organ (the blood
                // vessels, figure lines) so it reads as a solid shape in front of them.
                ctx.save();
                ctx.clip();
                ctx.globalAlpha = 1.0;
                ctx.fillStyle = bg;
                ctx.fillRect(0, 0, w, h);
                ctx.restore();

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


    // ── Pixel-art potion bottle (PP page) ───────────────────────────────────
    // An 11×14 sprite drawn as chunky pixels. The liquid level is the compound's
    // intake as a fraction of its daily ceiling, so the bottle doubles as a gauge.
    // Greyed out entirely when you haven't had any today.
    Component {
        id: potionComponent
        Canvas {
            id: potion
            property color liquid: window.blue
            property real fill: 0          // 0–1, how full to draw the bottle
            property bool active: false
            onLiquidChanged: requestPaint()
            onFillChanged: requestPaint()
            onActiveChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()

            // o = outline · c = cork · i = interior (glass or liquid) · . = empty
            readonly property var sprite: [
                "...ooooo...",
                "...occco...",
                "...occco...",
                "...oiiio...",
                "..oiiiiio..",
                ".oiiiiiiio.",
                "oiiiiiiiiio",
                "oiiiiiiiiio",
                "oiiiiiiiiio",
                "oiiiiiiiiio",
                "oiiiiiiiiio",
                ".oiiiiiiio.",
                "..oiiiiio..",
                "...ooooo..."
            ]
            onPaint: {
                var ctx = getContext("2d"); ctx.reset();
                var rows = sprite.length, cols = sprite[0].length;
                var px = Math.max(1, Math.floor(Math.min(width / cols, height / rows)));
                var ox = Math.floor((width - cols * px) / 2);
                var oy = Math.floor((height - rows * px) / 2);

                // interior spans rows 3–12; liquid stacks up from the bottom
                var iTop = 3, iBot = 12, span = iBot - iTop + 1;
                var nLiquid = Math.round(Math.max(0, Math.min(1, fill)) * span);
                var liquidFrom = iBot - nLiquid + 1;

                var cOutline = active ? Qt.darker(liquid, 2.4) : window.overlay0;
                var cCork    = active ? Qt.darker(liquid, 3.2) : window.overlay0;
                var cLiquid  = active ? liquid : window.overlay0;

                for (var r = 0; r < rows; r++) {
                    for (var c = 0; c < cols; c++) {
                        var ch = sprite[r].charAt(c);
                        if (ch === ".") continue;
                        var isLiquid = (ch === "i" && nLiquid > 0 && r >= liquidFrom);
                        if (ch === "o")      { ctx.globalAlpha = 1.0;  ctx.fillStyle = cOutline; }
                        else if (ch === "c") { ctx.globalAlpha = 1.0;  ctx.fillStyle = cCork; }
                        else if (isLiquid)   { ctx.globalAlpha = 0.95; ctx.fillStyle = cLiquid; }
                        else                 { ctx.globalAlpha = 0.45; ctx.fillStyle = window.surface1; }
                        ctx.fillRect(ox + c * px, oy + r * px, px, px);
                    }
                }
                // two-pixel glass highlight on the shoulder
                ctx.globalAlpha = active ? 0.5 : 0.2;
                ctx.fillStyle = "#ffffff";
                ctx.fillRect(ox + 2 * px, oy + 6 * px, px, px);
                ctx.fillRect(ox + 2 * px, oy + 7 * px, px, px);
                ctx.globalAlpha = 1.0;
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
                    textFormat: Text.PlainText
                    text: "󰙨"
                    font.family: "Iosevka Nerd Font"; font.pixelSize: s(20); color: window.blue
                }
                Text {
                    textFormat: Text.PlainText
                    text: window.userName
                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: s(16); color: window.text
                }
                Text {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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
                        Text { textFormat: Text.PlainText; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(12); color: window.restMode ? window.peach : window.subtext0 }
                        Text {
                            textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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

                    // Vital gauges: HP / AP / MP / EP / SP / FP / POT. Click one →
                    // its in-depth breakdown takes over the Life Signals module
                    // below; click again (or the ✕) for the default readout.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: s(232)   // 7 rows + the EP/SP divider
                        radius: s(12)
                        color: window.surface0
                        border.color: window.surface1; border.width: 1
                        clip: true
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: s(8)
                            spacing: s(4)
                            // The stack is split in two by a divider: what you PUT
                            // IN (fuel, water, training, sleep) above, what comes
                            // OUT of it (calm, energy, focus) below. Two Repeaters
                            // sharing one delegate — a single Repeater with a
                            // wrapped delegate made the rows fight over height.
                            Repeater {
                                model: [
                                    { key: "hp", label: "HP", accent: "red" },      // Fuel (kcal)
                                    { key: "pp", label: "PP", accent: "blue" },     // Potion Points (ml)
                                    { key: "ap", label: "AP", accent: "yellow" },   // Exercise (seconds)
                                    { key: "ep", label: "EP", accent: "mauve" }     // Sleep
                                ]
                                delegate: vitalRowComponent
                            }
                            Rectangle {                       // ── EP │ SP divider ──
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                Layout.leftMargin: s(6); Layout.rightMargin: s(6)
                                color: window.surface2
                            }
                            Repeater {
                                model: [
                                    { key: "sp", label: "SP", accent: "green" },    // Soul (calm)
                                    { key: "mp", label: "MP", accent: "peach" },    // Energy
                                    { key: "fp", label: "FP", accent: "teal" }      // Focus (0-400)
                                ]
                                delegate: vitalRowComponent
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

                        // DEFAULT: objective biometric proxies. (The lifestyle
                        // counters that used to live here — water, food, workout,
                        // mood, stress — are now the MP/HP/AP/EP/SP vital gauges.)
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: s(12)
                            spacing: s(8)
                            visible: window.focusedVital === ""

                            // Header + Resilience Index pill.
                            RowLayout {
                                Layout.fillWidth: true; spacing: s(7)
                                Text { textFormat: Text.PlainText; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(13); color: window.teal }
                                Text {
                                    textFormat: Text.PlainText
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
                                        Text { textFormat: Text.PlainText; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(9); color: resPillBg.rc }
                                        Text {
                                            textFormat: Text.PlainText
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
                            // ── The LONG-TERM stress pair (months-to-years timescale,
                            // deliberately NOT folded into SP's daily stress readout).
                            // WEAR = allostatic load: objective physiological damage.
                            //        Shown as z-drift (has resolution while you're still
                            //        healthy) with the clinical count behind it.
                            // PSS  = perceived stress: the subjective companion, which
                            //        still reads true at zero physiological damage.
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "WEAR";
                                    item.value = Qt.binding(function () {
                                        var al = window.allostatic;
                                        if (!al.reliable) {
                                            var gap = al.blindSystems.length
                                                ? (" · blind: " + al.blindSystems.length + " sys") : "";
                                            return al.measured + "/" + al.total + " markers" + gap;
                                        }
                                        var drift = (al.zMean > 0 ? "+" : "") + al.zMean;
                                        return "z " + drift + " " + Engine.allostaticDriftLabel(al)
                                             + " · " + al.score + " flag" + (al.score === 1 ? "" : "s");
                                    });
                                    item.trend = Qt.binding(function () {
                                        var al = window.allostatic;
                                        if (!al.reliable) return 0;
                                        return al.zMean < -0.2 ? 1 : (al.zMean < 0.5 ? 0 : -1);
                                    });
                                }
                            }
                            Loader {
                                Layout.fillWidth: true; sourceComponent: signalRowComponent
                                onLoaded: {
                                    item.label = "PSS-10";
                                    item.value = Qt.binding(function () {
                                        var p = window.pss;
                                        if (p.score === null) return "not taken — see pss.json";
                                        if (p.stale) return p.score + "/40 · stale (" + p.ageDays + "d) — retake";
                                        return p.score + "/40 · " + p.label
                                             + (p.due ? " · due" : " · " + p.ageDays + "d ago");
                                    });
                                    item.trend = Qt.binding(function () {
                                        var p = window.pss;
                                        if (p.score === null || p.stale) return 0;
                                        return p.score <= 13 ? 1 : (p.score <= 26 ? 0 : -1);
                                    });
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 1
                                Layout.topMargin: s(4); Layout.bottomMargin: s(2)
                                color: window.surface1
                            }
                            Text {
                                textFormat: Text.PlainText
                                text: "SUMMARY"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                            }
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: window.summary
                                font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.subtext1
                                wrapMode: Text.Wrap; lineHeight: 1.2
                            }
                            Item { Layout.fillHeight: true }
                        }

                        // FOCUSED: the clicked vital's in-depth breakdown, in place.
                        // Scrollable — the HP page (gauge + inputs + macros + pie + four
                        // meal slots) is taller than the module can show at once.
                        Flickable {
                            id: vitalScroll
                            anchors.fill: parent
                            anchors.margins: s(12)
                            visible: window.focusedVital !== ""
                            contentWidth: width
                            contentHeight: vitalFocus.implicitHeight
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            // always start a newly-opened page at the top
                            onVisibleChanged: if (visible) contentY = 0

                        ColumnLayout {
                            id: vitalFocus
                            width: vitalScroll.width
                            // HP packs the most in (gauge + macros + pie + 4 meal slots),
                            // so it runs tight to stay on one page; the other vitals keep
                            // the roomier spacing.
                            spacing: window.focusedVital === "hp" ? s(2) : s(9)
                            readonly property var info: window.focusedVital !== "" ? window.vitalInfo(window.focusedVital) : null
                            // Empty while the calendar is up (it takes this space) and on a
                            // day that was never logged.
                            readonly property var breakdown: (window.focusedVital !== "" && hasLog && !calMode)
                                ? window.vitalBreakdown(window.focusedVital) : []
                            // macro rows are pulled OUT of the main list and shown under the pie;
                            // `tail` rows (e.g. Nutrition) render AFTER the macro bars.
                            readonly property var breakdownMain: breakdown.filter(function (r) { return !r.macro && !r.tail; })
                            readonly property var breakdownMacros: breakdown.filter(function (r) { return r.macro; })
                            readonly property var breakdownTail: breakdown.filter(function (r) { return r.tail; })
                            readonly property color accent: !info ? window.blue
                                : (info.key === "ap" && window.apGold) ? window.gold
                                : window.accentColor(info.accent)
                            // The day being viewed (today = live state, past = archive).
                            readonly property var dst: window.dayState || window.st
                            readonly property bool hasLog: window.dayHas
                            readonly property int cur: (info && hasLog) ? dst.vitals[info.key] : 0
                            readonly property int max: info ? dst.vitals[info.key + "Max"] : 100
                            // HP/PP extras: target-segment marker bars + (HP) macro pie.
                            readonly property bool isHp: window.focusedVital === "hp"
                            readonly property bool isPp: window.focusedVital === "pp"
                            readonly property bool isAp: window.focusedVital === "ap"
                            readonly property bool isEp: window.focusedVital === "ep"
                            // EP: last night's hypnogram (null when no night was logged),
                            // and its quality score — shown ON the graph, not as a bar.
                            readonly property var sleep: (isEp && hasLog && !calMode) ? Engine.sleepSession(dst) : null
                            readonly property int sleepScore: isEp ? Engine.sleepQuality(dst) : 0
                            // AP: the workout tracker under the bars — today's sessions,
                            // each with its exercises and sets.
                            readonly property var workouts: (isAp && hasLog && !calMode) ? Engine.workoutLog(dst) : []
                            // PP: Caffeine / Alcohol / Sugar / meds as pixel-art potions —
                            // only the ones actually taken that day show up.
                            readonly property var potions: (isPp && hasLog && !calMode)
                                ? Engine.potionLines(dst).filter(function (p) { return p.active; })
                                : []
                            // HP: only the meal slots actually eaten that day.
                            readonly property var mealSlots: {
                                if (!isHp || !hasLog || calMode) return [];
                                var ml = dst.mealLog || {};
                                return [
                                    { slot: "Breakfast",       d: ml.breakfast },
                                    { slot: "Lunch",           d: ml.lunch },
                                    { slot: "Dinner",          d: ml.dinner },
                                    { slot: "Snacks & Drinks", d: ml.snacks }
                                ].filter(function (m) { return m.d && m.d.items && m.d.items.length > 0; });
                            }
                            // Small target-composition strip under the gauge:
                            //   HP → Base / Exercise / Bulk (of the calorie target)
                            //   PP → Base / Exercise / Heat (of the water target)
                            readonly property var segData: ((isHp || isPp) && hasLog)
                                ? Engine.gaugeSegments(dst, window.focusedVital) : null
                            readonly property var macros: (isHp && hasLog) ? Engine.macroReport(dst) : null
                            readonly property real drinkFrac: (isHp && hasLog)
                                ? ((dst.trackers.nutrition.drinkCalories || 0) / Math.max(1, max)) : 0
                            // With the calendar open, the grid TAKES the space the gauge and
                            // the page's main content normally occupy.
                            readonly property bool calMode: window.calendarOpen && window.focusedVital !== ""

                            // Lay out the segment labels centred under each segment;
                            // if a label would collide with an already-placed one,
                            // drop it to the lower row (a stem then connects it).
                            function segLabels(w) {
                                if (!segData) return [];
                                var out = [], cum = 0, tgt = Math.max(1, segData.target), charW = s(5.4);
                                for (var i = 0; i < segData.segs.length; i++) {
                                    var seg = segData.segs[i];
                                    if (seg.amount <= 0) { cum += seg.amount; continue; }
                                    var cx = (cum + seg.amount / 2) / tgt * w;
                                    var halfW = seg.label.length * charW / 2;
                                    var row = 0;
                                    for (var j = 0; j < out.length; j++)
                                        if (out[j].row === 0 && Math.abs(out[j].cx - cx) < (out[j].halfW + halfW + s(3))) { row = 1; break; }
                                    out.push({ text: seg.label, cx: cx, halfW: halfW, row: row });
                                    cum += seg.amount;
                                }
                                return out;
                            }

                            // Header: title + close.
                            RowLayout {
                                Layout.fillWidth: true; spacing: s(6)
                                Text {
                                    textFormat: Text.PlainText
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
                                    Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(11); color: window.subtext0 }
                                }
                            }

                            // ── DAY NAVIGATION (every vital): ‹ / › step one day; the
                            // calendar button jumps to any past date. Never past today. ──
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: s(4)

                                // ‹ previous day
                                Rectangle {
                                    Layout.preferredWidth: s(22); Layout.preferredHeight: s(20); radius: s(6)
                                    color: prevHov.hovered ? window.surface1 : window.surface0
                                    border.color: window.surface1; border.width: 1
                                    HoverHandler { id: prevHov; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: window.foodDayOffset -= 1 }
                                    Text {
                                        textFormat: Text.PlainText
                                        anchors.centerIn: parent; text: "‹"
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(12); color: window.subtext0
                                    }
                                }

                                // calendar — pick any past date (sits right of the ‹)
                                Rectangle {
                                    Layout.preferredWidth: s(24); Layout.preferredHeight: s(20); radius: s(6)
                                    color: (calHov.hovered || window.calendarOpen) ? window.surface1 : window.surface0
                                    border.color: window.calendarOpen ? vitalFocus.accent : window.surface1
                                    border.width: 1
                                    HoverHandler { id: calHov; cursorShape: Qt.PointingHandCursor }
                                    TapHandler {
                                        onTapped: {
                                            // open the grid on the month you're looking at
                                            var d = new Date();
                                            d.setDate(d.getDate() + window.foodDayOffset);
                                            window.calYear = d.getFullYear();
                                            window.calMonth = d.getMonth();
                                            window.calendarOpen = !window.calendarOpen;
                                        }
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        anchors.centerIn: parent; text: "󰃰"
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: s(11)
                                        color: window.calendarOpen ? vitalFocus.accent : window.subtext0
                                    }
                                }

                                // the day itself
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignHCenter
                                    text: window.foodDayLabel + (window.dayHas ? "" : "  · no log")
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9.5)
                                    color: window.dayHas ? window.subtext0 : window.overlay0
                                }

                                // › next day — disabled once you're back at today
                                Rectangle {
                                    Layout.preferredWidth: s(22); Layout.preferredHeight: s(20); radius: s(6)
                                    readonly property bool canNext: window.foodDayOffset < 0
                                    opacity: canNext ? 1.0 : 0.35
                                    color: (canNext && nextHov.hovered) ? window.surface1 : window.surface0
                                    border.color: window.surface1; border.width: 1
                                    HoverHandler { id: nextHov; cursorShape: parent.canNext ? Qt.PointingHandCursor : Qt.ArrowCursor }
                                    TapHandler { onTapped: if (parent.canNext) window.foodDayOffset += 1 }
                                    Text {
                                        textFormat: Text.PlainText
                                        anchors.centerIn: parent; text: "›"
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(12); color: window.subtext0
                                    }
                                }
                            }

                            // ── CALENDAR: sits INLINE, taking exactly the space the
                            // calorie gauge + macros normally occupy (meals stay put). ──
                            ColumnLayout {
                                visible: vitalFocus.calMode
                                Layout.fillWidth: true
                                Layout.topMargin: s(4)
                                spacing: s(4)

                                // ‹ Month Year › ✕
                                RowLayout {
                                    Layout.fillWidth: true; spacing: s(4)
                                    Rectangle {
                                        Layout.preferredWidth: s(20); Layout.preferredHeight: s(18); radius: s(5)
                                        color: cmPrev.hovered ? window.surface1 : "transparent"
                                        HoverHandler { id: cmPrev; cursorShape: Qt.PointingHandCursor }
                                        TapHandler { onTapped: window.calShift(-1) }
                                        Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: "‹"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(11); color: window.subtext0 }
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignHCenter
                                        text: window.monthNames[window.calMonth] + " " + window.calYear
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9.5); color: window.text
                                    }
                                    Rectangle {
                                        Layout.preferredWidth: s(20); Layout.preferredHeight: s(18); radius: s(5)
                                        color: cmNext.hovered ? window.surface1 : "transparent"
                                        HoverHandler { id: cmNext; cursorShape: Qt.PointingHandCursor }
                                        TapHandler { onTapped: window.calShift(1) }
                                        Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: "›"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(11); color: window.subtext0 }
                                    }
                                    Rectangle {
                                        Layout.preferredWidth: s(20); Layout.preferredHeight: s(18); radius: s(5)
                                        color: cmClose.hovered ? window.surface1 : "transparent"
                                        HoverHandler { id: cmClose; cursorShape: Qt.PointingHandCursor }
                                        TapHandler { onTapped: window.calendarOpen = false }
                                        Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(9); color: window.subtext0 }
                                    }
                                }

                                // weekday header
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 7; columnSpacing: s(1); rowSpacing: s(1)
                                    Repeater {
                                        model: ["S", "M", "T", "W", "T", "F", "S"]
                                        delegate: Text {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            text: modelData
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(7.5); color: window.overlay1
                                        }
                                    }
                                }

                                // day grid
                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 7; columnSpacing: s(1); rowSpacing: s(1)
                                    Repeater {
                                        model: vitalFocus.calMode ? window.calDays() : []
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: s(22)
                                            readonly property bool blank: modelData.d === 0
                                            readonly property bool selectable: !blank && !modelData.future
                                            readonly property bool isToday: modelData.off === 0 && !blank
                                            readonly property bool isSel: !blank && modelData.off === window.foodDayOffset
                                            radius: s(5)
                                            color: isSel ? vitalFocus.accent
                                                 : (selectable && dayHov.hovered) ? window.surface1
                                                 : "transparent"
                                            border.color: isToday && !isSel ? window.overlay1 : "transparent"
                                            border.width: 1
                                            HoverHandler {
                                                id: dayHov
                                                enabled: parent.selectable
                                                cursorShape: Qt.PointingHandCursor
                                            }
                                            TapHandler {
                                                enabled: parent.selectable
                                                onTapped: {
                                                    window.foodDayOffset = modelData.off;
                                                    window.calendarOpen = false;
                                                }
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                anchors.centerIn: parent
                                                visible: !parent.blank
                                                text: modelData.d
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5)
                                                color: parent.isSel ? window.base
                                                     : parent.selectable ? window.text
                                                     : window.overlay0
                                            }
                                        }
                                    }
                                }

                                // jump back to today
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: s(20)
                                    Layout.topMargin: s(2)
                                    radius: s(6)
                                    color: todayHov.hovered ? window.surface1 : window.surface0
                                    border.color: window.surface1; border.width: 1
                                    HoverHandler { id: todayHov; cursorShape: Qt.PointingHandCursor }
                                    TapHandler {
                                        onTapped: {
                                            window.foodDayOffset = 0;
                                            var t = new Date();
                                            window.calYear = t.getFullYear();
                                            window.calMonth = t.getMonth();
                                            window.calendarOpen = false;
                                        }
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        anchors.centerIn: parent; text: "Today"
                                        font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                                    }
                                }
                            }

                            // "this day was never logged" — shown instead of the page body
                            Text {
                                textFormat: Text.PlainText
                                visible: !vitalFocus.hasLog && !vitalFocus.calMode
                                Layout.fillWidth: true
                                Layout.topMargin: s(10)
                                horizontalAlignment: Text.AlignHCenter
                                text: "No log for this day."
                                font.family: "JetBrains Mono"; font.pixelSize: s(10); font.italic: true; color: window.overlay1
                            }

                            // Gauge: big value + bar.
                            RowLayout {
                                visible: !vitalFocus.calMode && vitalFocus.hasLog
                                Layout.fillWidth: true; spacing: s(5)
                                Text {
                                    textFormat: Text.PlainText
                                    text: vitalFocus.cur
                                    font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: s(34); color: vitalFocus.accent
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.alignment: Qt.AlignBottom; Layout.bottomMargin: s(6)
                                    text: "/ " + vitalFocus.max
                                    font.family: "JetBrains Mono"; font.pixelSize: s(12); color: window.subtext0
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.alignment: Qt.AlignBottom; Layout.bottomMargin: s(6)
                                    text: Math.round(vitalFocus.max > 0 ? vitalFocus.cur / vitalFocus.max * 100 : 0) + "%"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(12); color: window.subtext1
                                }
                            }
                            // Big gauge bar: fill + (HP) drink segment + overflow +
                            // (HP/PP) target-composition marker strip at the bottom.
                            Rectangle {
                                id: gtrack
                                visible: !vitalFocus.calMode && vitalFocus.hasLog
                                Layout.fillWidth: true; Layout.preferredHeight: s(11)
                                radius: s(5.5); color: window.surface1; clip: true
                                readonly property real fillFrac: Math.max(0, Math.min(1, vitalFocus.max > 0 ? vitalFocus.cur / vitalFocus.max : 0))
                                readonly property color acc: window.restMode ? window.overlay0 : vitalFocus.accent
                                // base fill
                                Rectangle {
                                    width: parent.width * parent.fillFrac
                                    height: parent.height; radius: parent.radius
                                    color: parent.acc
                                    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                }
                                // drink segment (HP): last drinkFrac of the fill, darker
                                Rectangle {
                                    visible: vitalFocus.drinkFrac > 0
                                    x: parent.width * Math.max(0, parent.fillFrac - vitalFocus.drinkFrac)
                                    width: parent.width * Math.max(0, Math.min(parent.fillFrac, vitalFocus.drinkFrac))
                                    height: parent.height; radius: parent.radius
                                    color: Qt.darker(parent.acc, 1.7)
                                }
                                // overflow: second lap when you exceed the target
                                Rectangle {
                                    visible: vitalFocus.max > 0 && vitalFocus.cur / vitalFocus.max > 1
                                    width: parent.width * Math.min(1, (vitalFocus.max > 0 ? vitalFocus.cur / vitalFocus.max : 0) - 1)
                                    height: parent.height; radius: parent.radius
                                    color: Qt.lighter(parent.acc, 1.5)
                                    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                }
                                // target-composition marker strip (PP: base / exercise / heat)
                                Row {
                                    visible: vitalFocus.segData !== null
                                    anchors.left: parent.left; anchors.bottom: parent.bottom
                                    height: s(2.5)
                                    Repeater {
                                        model: vitalFocus.segData ? vitalFocus.segData.segs : []
                                        delegate: Rectangle {
                                            required property var modelData
                                            required property int index
                                            width: gtrack.width * Math.max(0, modelData.amount) / Math.max(1, vitalFocus.segData.target)
                                            height: parent.height
                                            color: [window.overlay1, window.peach, window.teal][index % 3]
                                            opacity: 0.95
                                        }
                                    }
                                }
                            }
                            // segment labels, centred under each segment, collision-lowered with stems
                            Item {
                                id: segLabelBox
                                visible: vitalFocus.segData !== null && !vitalFocus.calMode
                                Layout.fillWidth: true
                                Layout.preferredHeight: (vitalFocus.segData && !vitalFocus.calMode) ? s(22) : 0
                                Repeater {
                                    model: (vitalFocus.segData && segLabelBox.width > 0) ? vitalFocus.segLabels(segLabelBox.width) : []
                                    delegate: Item {
                                        required property var modelData
                                        anchors.fill: parent
                                        Rectangle {   // stem for lowered labels
                                            visible: modelData.row > 0
                                            x: modelData.cx; width: 1
                                            y: 0; height: s(10)
                                            color: window.overlay1
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            x: Math.max(0, Math.min(segLabelBox.width - width, modelData.cx - width / 2))
                                            y: modelData.row > 0 ? s(10) : s(1)
                                            text: modelData.text
                                            font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.subtext0
                                        }
                                    }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 1
                                Layout.topMargin: s(2); Layout.bottomMargin: s(1)
                                color: window.surface1
                            }

                            Text {
                                textFormat: Text.PlainText
                                // HP has no plain rows any more (macros live under the
                                // pie, meals under their own header) — don't leave an
                                // orphaned section title behind.
                                visible: vitalFocus.breakdownMain.length > 0
                                text: vitalFocus.isPp ? "INGREDIENTS" : "CONTRIBUTING INPUTS"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                            }
                            Repeater {
                                model: vitalFocus.breakdownMain
                                delegate: RowLayout {
                                    required property var modelData
                                    // counter rows (e.g. Meals) drop the bar and centre
                                    // the label + number as a pair
                                    readonly property bool isCounter: modelData.counter === true
                                    Layout.fillWidth: true; spacing: s(7)
                                    Item { visible: isCounter; Layout.fillWidth: true }
                                    Text {
                                        textFormat: Text.PlainText
                                        Layout.preferredWidth: isCounter ? implicitWidth : s(70)
                                        text: modelData.label
                                        font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.text; elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        visible: !isCounter
                                        Layout.fillWidth: true; Layout.preferredHeight: s(8)
                                        radius: s(4); color: window.surface1; clip: true
                                        readonly property color acc: window.restMode ? window.overlay0 : vitalFocus.accent
                                        // base fill (0–100%)
                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(1, modelData.ratio || 0))
                                            height: parent.height; radius: parent.radius
                                            color: parent.acc
                                            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                        }
                                        // stacked segment (e.g. calories-from-drinks) — the last
                                        // `seg` fraction of the fill, in a darker shade
                                        Rectangle {
                                            visible: (modelData.seg || 0) > 0
                                            x: parent.width * Math.max(0, Math.min(1, modelData.ratio || 0) - (modelData.seg || 0))
                                            width: parent.width * Math.max(0, Math.min(Math.min(1, modelData.ratio || 0), modelData.seg || 0))
                                            height: parent.height; radius: parent.radius
                                            color: Qt.darker(parent.acc, 1.7)
                                        }
                                        // OVERFLOW: a second lap from the left when the counter
                                        // exceeds its target, in a lighter shade of the same colour
                                        Rectangle {
                                            visible: (modelData.ratio || 0) > 1
                                            width: parent.width * Math.min(1, (modelData.ratio || 0) - 1)
                                            height: parent.height; radius: parent.radius
                                            color: Qt.lighter(parent.acc, 1.5)
                                            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                        }
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        Layout.preferredWidth: isCounter ? implicitWidth : s(64)
                                        horizontalAlignment: isCounter ? Text.AlignLeft : Text.AlignRight
                                        text: modelData.valueText
                                        font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                                    }
                                    Item { visible: isCounter; Layout.fillWidth: true }
                                }
                            }

                            // ── WORKOUT (AP): today's sessions, then the heart-rate
                            // tracker — minutes in each HR zone, with Zone 2 (the AP
                            // target band) called out. ──
                            Text {
                                textFormat: Text.PlainText
                                visible: vitalFocus.isAp && vitalFocus.hasLog && !vitalFocus.calMode
                                Layout.topMargin: s(7)
                                text: "WORKOUT"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                            }
                            // Each SESSION: name + summary, then its exercises, each with
                            // its numbered sets (weight × reps, PR flagged).
                            Repeater {
                                model: vitalFocus.workouts
                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.topMargin: s(3)
                                    spacing: s(1)

                                    // session header
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: s(6)
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.minimumWidth: 0
                                            text: modelData.name
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9.5); color: window.text
                                            elide: Text.ElideRight
                                        }
                                        Item { Layout.fillWidth: true }
                                        Text {
                                            textFormat: Text.PlainText
                                            text: Engine.sessionSummary(modelData)
                                            font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.subtext0
                                        }
                                    }

                                    // exercises
                                    Repeater {
                                        model: modelData.exercises || []
                                        delegate: ColumnLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            Layout.topMargin: s(2)
                                            spacing: 0

                                            // exercise name + its volume / set count
                                            RowLayout {
                                                Layout.fillWidth: true; spacing: s(6)
                                                Layout.leftMargin: s(6)
                                                Text {
                                                    textFormat: Text.PlainText
                                                    Layout.minimumWidth: 0
                                                    text: modelData.name
                                                    font.family: "JetBrains Mono"; font.pixelSize: s(9); color: vitalFocus.accent
                                                    elide: Text.ElideRight
                                                }
                                                Item { Layout.fillWidth: true }
                                                Text {
                                                    textFormat: Text.PlainText
                                                    visible: !!modelData.sets
                                                    text: Engine.exerciseVolume(modelData) > 0
                                                          ? Engine.exerciseVolume(modelData) + " kg" : ""
                                                    font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.overlay1
                                                }
                                            }

                                            // STRENGTH — one row per set: № · weight × reps · PR
                                            Repeater {
                                                model: modelData.sets || []
                                                delegate: RowLayout {
                                                    required property var modelData
                                                    required property int index
                                                    Layout.fillWidth: true
                                                    Layout.leftMargin: s(14)
                                                    spacing: s(6)
                                                    Text {
                                                        textFormat: Text.PlainText
                                                        Layout.preferredWidth: s(12)
                                                        text: (index + 1) + ""
                                                        font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.overlay1
                                                    }
                                                    Text {
                                                        textFormat: Text.PlainText
                                                        Layout.minimumWidth: 0
                                                        text: modelData.kg + " kg × " + modelData.reps
                                                        font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext1
                                                        elide: Text.ElideRight
                                                    }
                                                    Item { Layout.fillWidth: true }
                                                    // PR badge
                                                    Rectangle {
                                                        visible: modelData.pr === true
                                                        Layout.preferredWidth: s(20); Layout.preferredHeight: s(11)
                                                        radius: s(3)
                                                        color: window.gold
                                                        Text {
                                                            textFormat: Text.PlainText
                                                            anchors.centerIn: parent; text: "PR"
                                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(7); color: window.base
                                                        }
                                                    }
                                                }
                                            }

                                            // CARDIO — no sets; time / distance / avg HR
                                            Text {
                                                textFormat: Text.PlainText
                                                visible: !!modelData.cardio
                                                Layout.fillWidth: true
                                                Layout.leftMargin: s(14)
                                                text: modelData.cardio
                                                      ? (modelData.cardio.minutes + " min"
                                                         + (modelData.cardio.km ? " · " + modelData.cardio.km + " km" : "")
                                                         + (modelData.cardio.avgHr ? " · avg " + modelData.cardio.avgHr + " bpm" : ""))
                                                      : ""
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext1
                                            }
                                        }
                                    }
                                }
                            }
                            Text {
                                textFormat: Text.PlainText
                                visible: vitalFocus.isAp && vitalFocus.hasLog && !vitalFocus.calMode
                                         && vitalFocus.workouts.length === 0
                                text: "no session logged yet"
                                font.family: "JetBrains Mono"; font.pixelSize: s(9); font.italic: true; color: window.overlay1
                            }

                            // ── SLEEP (EP): last night as a hypnogram — Awake / REM /
                            // Core / Deep lanes across the night, then stage totals and
                            // the times you woke up. ──
                            RowLayout {
                                visible: vitalFocus.isEp && vitalFocus.sleep !== null
                                Layout.fillWidth: true
                                Layout.topMargin: s(7)
                                spacing: s(6)
                                Text {
                                    textFormat: Text.PlainText
                                    text: "SLEEP"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                                }
                                // quality score — green ≥80, yellow ≥60, red below
                                Rectangle {
                                    Layout.preferredWidth: s(26); Layout.preferredHeight: s(12)
                                    radius: s(3)
                                    readonly property int q: vitalFocus.sleepScore
                                    color: window.restMode ? window.overlay0
                                         : q >= 80 ? window.green
                                         : q >= 60 ? window.yellow
                                                   : window.red
                                    Text {
                                        textFormat: Text.PlainText
                                        anchors.centerIn: parent
                                        text: "Q" + parent.q
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(7.5); color: window.base
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    textFormat: Text.PlainText
                                    text: vitalFocus.sleep
                                          ? (vitalFocus.sleep.bedtime + " → " + vitalFocus.sleep.wake
                                             + "  ·  " + Engine.fmtDur(vitalFocus.sleep.asleepMin))
                                          : ""
                                    font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.subtext0
                                }
                            }

                            // the hypnogram itself
                            Canvas {
                                id: hypno
                                visible: vitalFocus.isEp && vitalFocus.sleep !== null
                                Layout.fillWidth: true
                                Layout.preferredHeight: s(92)
                                property var ss: vitalFocus.sleep
                                onSsChanged: requestPaint()
                                onWidthChanged: requestPaint()
                                onPaint: {
                                    var ctx = getContext("2d"); ctx.reset();
                                    if (!ss || !ss.segments.length) return;

                                    var gutter = s(30);          // lane-label column
                                    var axisH  = s(13);          // clock labels along the bottom
                                    var gw     = Math.max(1, width - gutter);
                                    var laneArea = Math.max(4, height - axisH);
                                    var laneH  = laneArea / 4;
                                    var span   = Math.max(1, ss.spanMin);
                                    var names  = ["Awake", "REM", "Core", "Deep"];
                                    var cols   = [window.peach, window.teal, window.blue, window.mauve];
                                    function xAt(min) { return gutter + (min / span) * gw; }

                                    // ── WIND-DOWN band: screens-off → bedtime ──
                                    if (ss.windDownMin > 0) {
                                        ctx.globalAlpha = 0.10;
                                        ctx.fillStyle = window.peach;
                                        ctx.fillRect(gutter, 0, xAt(ss.bedOffsetMin) - gutter, laneArea);
                                        ctx.globalAlpha = 1.0;
                                    }

                                    // ── hour ticks (the clock axis — consistency at a glance) ──
                                    // Every hour gets a gridline; labels thin out when the
                                    // night is long enough that they'd collide.
                                    ctx.font = "600 " + s(7) + "px 'JetBrains Mono'";
                                    ctx.textBaseline = "top";
                                    ctx.textAlign = "center";
                                    var labelEvery = Math.max(1, Math.ceil(ss.ticks.length / 5));
                                    for (var t = 0; t < ss.ticks.length; t++) {
                                        var tx = xAt(ss.ticks[t].offset);
                                        ctx.globalAlpha = 0.30;
                                        ctx.fillStyle = window.overlay1;
                                        ctx.fillRect(tx, 0, 1, laneArea);
                                        if (t % labelEvery === 0) {
                                            ctx.globalAlpha = 1.0;
                                            ctx.fillStyle = window.overlay1;
                                            ctx.fillText(ss.ticks[t].label, tx, laneArea + s(2));
                                        }
                                        ctx.globalAlpha = 1.0;
                                    }
                                    ctx.textAlign = "left";

                                    // ── bedtime marker: the line you actually got in bed ──
                                    if (ss.windDownMin > 0) {
                                        var bx = xAt(ss.bedOffsetMin);
                                        ctx.globalAlpha = 0.9;
                                        ctx.fillStyle = window.peach;
                                        ctx.fillRect(bx - 0.5, 0, 1.5, laneArea);
                                        ctx.globalAlpha = 1.0;
                                    }

                                    // ── lane labels + faint guide line per lane ──
                                    ctx.textBaseline = "middle";
                                    for (var l = 0; l < 4; l++) {
                                        ctx.globalAlpha = 1.0;
                                        ctx.fillStyle = window.overlay1;
                                        ctx.fillText(names[l], 0, l * laneH + laneH / 2);
                                        ctx.globalAlpha = 0.30;
                                        ctx.fillStyle = window.surface1;
                                        ctx.fillRect(gutter, l * laneH + laneH / 2, gw, 1);
                                    }

                                    // ── one rounded block per segment, in its stage's lane ──
                                    var pad = laneH * 0.24;
                                    var bh  = Math.max(2, laneH - 2 * pad);
                                    var r   = Math.min(bh / 2, s(2));
                                    ctx.globalAlpha = 0.95;
                                    for (var i = 0; i < ss.segments.length; i++) {
                                        var g  = ss.segments[i];
                                        var x  = xAt(ss.bedOffsetMin + g.startMin);
                                        var bw = Math.max(1.5, (g.min / span) * gw);
                                        var y  = g.lane * laneH + pad;
                                        ctx.fillStyle = cols[g.lane];
                                        ctx.beginPath();
                                        ctx.moveTo(x + r, y);
                                        ctx.lineTo(x + bw - r, y);
                                        ctx.quadraticCurveTo(x + bw, y, x + bw, y + r);
                                        ctx.lineTo(x + bw, y + bh - r);
                                        ctx.quadraticCurveTo(x + bw, y + bh, x + bw - r, y + bh);
                                        ctx.lineTo(x + r, y + bh);
                                        ctx.quadraticCurveTo(x, y + bh, x, y + bh - r);
                                        ctx.lineTo(x, y + r);
                                        ctx.quadraticCurveTo(x, y, x + r, y);
                                        ctx.closePath();
                                        ctx.fill();
                                    }
                                    ctx.globalAlpha = 1.0;
                                }
                            }
                            // wind-down: when the screens actually went dark
                            RowLayout {
                                visible: vitalFocus.isEp && vitalFocus.sleep !== null
                                         && vitalFocus.sleep.windDownMin > 0
                                Layout.fillWidth: true
                                Layout.leftMargin: s(30)
                                spacing: s(5)
                                Rectangle {
                                    Layout.preferredWidth: s(7); Layout.preferredHeight: s(7)
                                    radius: s(2); opacity: 0.45
                                    color: window.peach
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: vitalFocus.sleep
                                          ? ("devices off " + vitalFocus.sleep.screensOff + " · "
                                             + Engine.fmtDur(vitalFocus.sleep.windDownMin) + " wind-down before bed")
                                          : ""
                                    font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.subtext1
                                }
                            }

                            // stage key — no bars (the graph IS the bars); two per row
                            GridLayout {
                                visible: vitalFocus.isEp && vitalFocus.sleep !== null
                                Layout.fillWidth: true
                                Layout.topMargin: s(3)
                                columns: 2
                                columnSpacing: s(10)
                                rowSpacing: s(3)
                                Repeater {
                                    model: vitalFocus.sleep ? vitalFocus.sleep.stages : []
                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        spacing: s(5)
                                        readonly property color sc: window.accentColor(modelData.colour)
                                        Rectangle {
                                            Layout.preferredWidth: s(7); Layout.preferredHeight: s(7)
                                            radius: s(2)
                                            color: window.restMode ? window.overlay0 : sc
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.minimumWidth: 0
                                            text: modelData.name
                                            font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.text
                                            elide: Text.ElideRight
                                        }
                                        Item { Layout.fillWidth: true }
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.minimumWidth: 0
                                            text: Engine.fmtDur(modelData.min) + "  " + modelData.pct + "%"
                                            font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.subtext0
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                            // wake-ups
                            Text {
                                textFormat: Text.PlainText
                                visible: vitalFocus.isEp && vitalFocus.sleep !== null
                                Layout.fillWidth: true
                                Layout.topMargin: s(2)
                                text: !vitalFocus.sleep ? ""
                                      : vitalFocus.sleep.wakeUps === 0
                                        ? "slept through — no wake-ups"
                                        : (vitalFocus.sleep.wakeUps
                                           + (vitalFocus.sleep.wakeUps === 1 ? " wake-up · " : " wake-ups · ")
                                           + vitalFocus.sleep.wakeTimes.join(", "))
                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext1
                            }

                            // ── THE WEEK BEFORE: sleep quality for the 7 nights leading
                            // up to this one, so a bad night reads in context. ──
                            RowLayout {
                                visible: vitalFocus.isEp && !vitalFocus.calMode
                                Layout.fillWidth: true
                                Layout.topMargin: s(7)
                                spacing: s(6)
                                Text {
                                    textFormat: Text.PlainText
                                    text: "7 NIGHTS BEFORE"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    textFormat: Text.PlainText
                                    text: window.weekSleepAvg > 0 ? ("avg Q" + window.weekSleepAvg) : "no history"
                                    font.family: "JetBrains Mono"; font.pixelSize: s(8); color: window.subtext0
                                }
                            }
                            RowLayout {
                                visible: vitalFocus.isEp && !vitalFocus.calMode
                                Layout.fillWidth: true
                                Layout.topMargin: s(2)
                                spacing: s(4)
                                Repeater {
                                    model: window.weekSleep
                                    delegate: ColumnLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        spacing: s(2)

                                        // Stacked bar: Deep at the bottom, then Core, then
                                        // REM — the same colours as the hypnogram lanes.
                                        // Bar height = time ASLEEP (8 h fills the track), so
                                        // duration and architecture read off one shape.
                                        Item {
                                            id: nightBar
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: s(84)
                                            readonly property real scale: Math.max(1, window.weekSleepScale)
                                            function h(min) { return nightBar.height * Math.min(1, min / scale); }

                                            Rectangle {   // faint track
                                                anchors.fill: parent
                                                radius: s(3)
                                                color: window.surface1
                                                opacity: 0.45
                                            }
                                            // the stack, clipped to the rounded track
                                            Item {
                                                anchors.fill: parent
                                                clip: true
                                                // DEEP (bottom)
                                                Rectangle {
                                                    id: segDeep
                                                    anchors.left: parent.left; anchors.right: parent.right
                                                    anchors.bottom: parent.bottom
                                                    height: nightBar.h(modelData.deep)
                                                    color: window.restMode ? window.overlay0 : window.mauve
                                                    Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                                }
                                                // CORE (middle)
                                                Rectangle {
                                                    id: segCore
                                                    anchors.left: parent.left; anchors.right: parent.right
                                                    anchors.bottom: segDeep.top
                                                    height: nightBar.h(modelData.core)
                                                    color: window.restMode ? window.overlay0 : window.blue
                                                    Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                                }
                                                // REM (top)
                                                Rectangle {
                                                    anchors.left: parent.left; anchors.right: parent.right
                                                    anchors.bottom: segCore.top
                                                    height: nightBar.h(modelData.rem)
                                                    color: window.restMode ? window.overlay0 : window.teal
                                                    Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                                }
                                            }
                                        }

                                        // hours asleep
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            text: modelData.has ? (Math.round(modelData.asleep / 6) / 10) + "h" : "–"
                                            font.family: "JetBrains Mono"; font.pixelSize: s(7)
                                            color: modelData.has ? window.subtext0 : window.overlay0
                                        }
                                        // quality score, coloured on the same thresholds as the badge
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            text: modelData.has ? ("Q" + modelData.q) : ""
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(7)
                                            color: !modelData.has ? window.overlay0
                                                 : modelData.q >= 80 ? window.green
                                                 : modelData.q >= 60 ? window.yellow
                                                                     : window.red
                                        }
                                        // weekday initial
                                        Text {
                                            textFormat: Text.PlainText
                                            Layout.fillWidth: true
                                            horizontalAlignment: Text.AlignHCenter
                                            text: modelData.letter
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(7.5)
                                            color: window.overlay1
                                        }
                                    }
                                }
                            }

                            // ── POTION EFFECTS (PP): Caffeine / Alcohol / Sugar as
                            // pixel-art bottles with their buffs and debuffs. Only the
                            // ones you've actually drunk today appear here. ──
                            Text {
                                textFormat: Text.PlainText
                                visible: vitalFocus.isPp && vitalFocus.potions.length > 0
                                Layout.topMargin: s(7)
                                text: "POTION EFFECTS"
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                            }
                            Repeater {
                                model: vitalFocus.potions
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.topMargin: s(2)
                                    spacing: s(8)
                                    // the bottle colour comes from the potion's own def
                                    readonly property color potColor: window.accentColor(modelData.colour)
                                    // the bottle
                                    Loader {
                                        sourceComponent: potionComponent
                                        Layout.preferredWidth: s(30)
                                        Layout.preferredHeight: s(40)
                                        Layout.alignment: Qt.AlignTop
                                        onLoaded: {
                                            item.liquid = Qt.binding(function () { return potColor; });
                                            item.fill   = Qt.binding(function () { return modelData.fill; });
                                            item.active = true;
                                        }
                                    }
                                    // name + amount, then buffs / debuffs
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        spacing: s(1)
                                        RowLayout {
                                            Layout.fillWidth: true; spacing: s(6)
                                            Text {
                                                textFormat: Text.PlainText
                                                text: modelData.name
                                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9.5); color: window.text
                                            }
                                            Item { Layout.fillWidth: true }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: modelData.amount
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: potColor
                                            }
                                        }
                                        Repeater {
                                            model: modelData.buffs
                                            delegate: Text {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                text: "▲ " + modelData
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.green
                                                wrapMode: Text.Wrap
                                            }
                                        }
                                        Repeater {
                                            model: modelData.debuffs
                                            delegate: Text {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                text: "▼ " + modelData
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.red
                                                wrapMode: Text.Wrap
                                            }
                                        }
                                    }
                                }
                            }

                            // ── MACROS (HP): macro + nutrient VALUES listed on the
                            // LEFT (no bars, each with a colour swatch matching its pie
                            // slice); the pie chart sits on the RIGHT. Inner pie = the
                            // ideal split; outer ring = what you've eaten today. ──
                            RowLayout {
                                visible: vitalFocus.isHp && !vitalFocus.calMode && vitalFocus.hasLog
                                Layout.fillWidth: true
                                spacing: s(10)

                                // LEFT: text values, no bars. minimumWidth 0 so this column
                                // can be squeezed rather than forcing the page to overflow.
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: s(9)
                                    Text {
                                        textFormat: Text.PlainText
                                        text: "MACROS"
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                                    }
                                    Repeater {
                                        model: vitalFocus.breakdownMacros
                                        delegate: RowLayout {
                                            required property var modelData
                                            required property int index
                                            readonly property color macroColor: [window.macroProtein, window.macroCarb, window.macroFat][index % 3]
                                            Layout.fillWidth: true; spacing: s(6)
                                            Rectangle {   // colour swatch = pie slice
                                                Layout.preferredWidth: s(7); Layout.preferredHeight: s(7)
                                                radius: s(2)
                                                color: window.restMode ? window.overlay0 : macroColor
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: modelData.label
                                                font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.text
                                            }
                                            Item { Layout.fillWidth: true }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: modelData.valueText
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                                            }
                                        }
                                    }
                                    // nutrient line(s) — Nutrition
                                    Repeater {
                                        model: vitalFocus.breakdownTail
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true; spacing: s(6)
                                            Text {
                                                textFormat: Text.PlainText
                                                text: modelData.label
                                                font.family: "JetBrains Mono"; font.pixelSize: s(9.5); color: window.text
                                            }
                                            Item { Layout.fillWidth: true }
                                            Text {
                                                textFormat: Text.PlainText
                                                text: modelData.valueText
                                                font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                                            }
                                        }
                                    }
                                }

                                // RIGHT: the pie chart. Keep it narrow enough that the
                                // row's MINIMUM width still fits the panel — otherwise the
                                // layout overflows and clips the right edge of the page.
                                Item {
                                    Layout.preferredWidth: s(120)
                                    Layout.maximumWidth: s(120)
                                    Layout.preferredHeight: s(120)
                                    Layout.alignment: Qt.AlignVCenter
                                    Canvas {
                                        id: macroPie
                                        anchors.centerIn: parent
                                        width: Math.max(1, Math.min(parent.width, parent.height))
                                        height: width
                                        property var mr: vitalFocus.macros
                                        property color cProtein: window.macroProtein
                                        property color cCarb: window.macroCarb
                                        property color cFat: window.macroFat
                                        onMrChanged: requestPaint()
                                        onWidthChanged: requestPaint()
                                        onPaint: {
                                            var ctx = getContext("2d"); ctx.reset();
                                            if (!mr) return;
                                            var cx = width / 2, cy = height / 2;
                                            var R = Math.min(width, height) / 2;
                                            var rPie = R * 0.42, rMid = R * 0.60, ringW = R * 0.22;
                                            var cols = [cProtein, cCarb, cFat];
                                            var targ = [mr.target.proteinPct / 100, mr.target.carbPct / 100, mr.target.fatPct / 100];
                                            var cn   = [mr.consumed.protein, mr.consumed.carb, mr.consumed.fat];
                                            // ACTUAL consumed split, by CALORIES (protein/carb 4, fat 9 kcal/g)
                                            var ck = [cn[0] * 4, cn[1] * 4, cn[2] * 9];
                                            var totalK = ck[0] + ck[1] + ck[2];
                                            var cons = totalK > 0 ? [ck[0] / totalK, ck[1] / totalK, ck[2] / totalK] : [0, 0, 0];

                                            // INNER pie = the ideal (target) split
                                            var a = -Math.PI / 2;
                                            for (var i = 0; i < 3; i++) {
                                                var sweep = targ[i] * 2 * Math.PI;
                                                ctx.beginPath(); ctx.moveTo(cx, cy);
                                                ctx.arc(cx, cy, rPie, a, a + sweep); ctx.closePath();
                                                ctx.fillStyle = cols[i]; ctx.globalAlpha = 0.9; ctx.fill();
                                                a += sweep;
                                            }
                                            // OUTER ring = the ACTUAL macro split of what you've eaten today
                                            ctx.globalAlpha = 1.0; ctx.lineWidth = ringW; ctx.lineCap = "butt";
                                            if (totalK > 0) {
                                                var b = -Math.PI / 2;
                                                for (var j = 0; j < 3; j++) {
                                                    var sw = cons[j] * 2 * Math.PI;
                                                    if (sw <= 0) continue;
                                                    ctx.beginPath();
                                                    ctx.arc(cx, cy, rMid, b + 0.015, b + sw - 0.015);
                                                    ctx.strokeStyle = cols[j]; ctx.stroke();
                                                    b += sw;
                                                }
                                            } else {
                                                ctx.globalAlpha = 0.18; ctx.beginPath();
                                                ctx.arc(cx, cy, rMid, 0, 2 * Math.PI);
                                                ctx.strokeStyle = window.overlay1; ctx.stroke();
                                            }
                                            ctx.globalAlpha = 1.0;
                                        }
                                    }
                                }
                            }

                            // ── MEALS: the section header carries the meal COUNT, which
                            // ticks up as you eat. Only slots you've actually eaten show
                            // up — an untouched Breakfast simply isn't listed. ──
                            RowLayout {
                                visible: vitalFocus.isHp && !vitalFocus.calMode && vitalFocus.hasLog
                                Layout.fillWidth: true
                                Layout.topMargin: s(2)
                                spacing: s(6)
                                Text {
                                    textFormat: Text.PlainText
                                    text: "MEALS"
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(8); font.letterSpacing: s(1); color: window.overlay1
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    textFormat: Text.PlainText
                                    text: (vitalFocus.dst.trackers.nutrition.meals || 0) + " / "
                                          + (vitalFocus.dst.trackers.nutrition.mealTarget || 3)
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9); color: window.subtext0
                                }
                            }
                            // nothing eaten at all on this day
                            Text {
                                textFormat: Text.PlainText
                                visible: vitalFocus.isHp && vitalFocus.hasLog && !vitalFocus.calMode && vitalFocus.mealSlots.length === 0
                                text: "nothing logged yet"
                                font.family: "JetBrains Mono"; font.pixelSize: s(9); font.italic: true; color: window.overlay1
                            }
                            Repeater {
                                model: vitalFocus.mealSlots
                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.topMargin: s(2)
                                    spacing: 0
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: s(6)
                                        Text {
                                            textFormat: Text.PlainText
                                            text: modelData.slot
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(9.5); color: window.text
                                        }
                                        Item { Layout.fillWidth: true }
                                        Text {
                                            textFormat: Text.PlainText
                                            text: (modelData.d && modelData.d.kcal) ? modelData.d.kcal + " kcal" : ""
                                            font.family: "JetBrains Mono"; font.pixelSize: s(8.5); color: window.subtext0
                                        }
                                    }
                                    // the meal's items, indented beneath the slot name
                                    Repeater {
                                        model: (modelData.d && modelData.d.items) ? modelData.d.items : []
                                        delegate: Text {
                                            required property var modelData
                                            Layout.fillWidth: true; Layout.leftMargin: s(8)
                                            text: "· " + modelData
                                            font.family: "JetBrains Mono"; font.pixelSize: s(9); color: window.subtext1
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }
                            }

                        }
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
                                    // The original transparent anatomical heart
                                    // (red line-drawing, white keyed out).
                                    source: "anatomical_heart.png"
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true; asynchronous: true
                                    opacity: 0.9
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
                                    // 30fps, not 60: this window is a FULL-SCREEN layer-shell
                                    // surface, so every tick that moves heartbeat.scale repaints
                                    // the whole 3440x1440 surface. A heartbeat pulse is perfectly
                                    // legible at 30fps and it halves the repaint cost.
                                    interval: 32; repeat: true
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

                            // ── CIRCULATORY OVERLAY ──
                            // The circulatory drawing (pre-fitted to the 958x966 frame)
                            // split into four 1:1 layers. The CORE is heart-red so the
                            // trunk vessels match the beating heart. The ARM and LEG
                            // layers are GREY (the figure's line-art grey) until you
                            // train that group — a group worked TODAY fades to heart-red.
                            //
                            // PERF: these used to be ColorOverlay (a shader per layer).
                            // The beating heart repaints this FULL-SCREEN surface ~30x/s,
                            // and Qt re-ran all four shaders on every one of those frames
                            // — 25% CPU while the sheet was open, for a tint that only
                            // changes when you finish a workout. `cached: true` did not
                            // help. The tints are now PRE-BAKED into _grey/_red PNGs and
                            // cross-faded with plain opacity, so there is no shader in the
                            // scene at all: 25% -> ~0%. Regenerate them with:
                            //   magick circ_X.png -alpha set -channel RGB \
                            //          -fill "#9f2126" -colorize 100 +channel circ_X_red.png
                            Item {
                                id: anatomy
                                // Nudged up and scaled down a touch so the vessels sit
                                // inside the figure's outline (hands and feet especially).
                                anchors.centerIn: vitImg
                                anchors.verticalCenterOffset: -vitImg.paintedHeight * 0.006
                                width: Math.max(1, vitImg.paintedWidth * 0.97)
                                height: Math.max(1, vitImg.paintedHeight * 0.97)

                                // 1.0 only for a group worked TODAY (pump); recovery and
                                // rested both read 0 -> stay grey.
                                function limbFresh(part) {
                                    var v = Engine.veinState(window.st, part === "legs" ? "legs" : "arms");
                                    return v.mode === "pump" ? 1.0 : 0.0;
                                }

                                // core: heart-red, matching the beating heart
                                Image {
                                    anchors.fill: parent
                                    source: "circ_core_red.png"
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true; asynchronous: true
                                    sourceSize.width: 479; sourceSize.height: 483
                                    opacity: window.restMode ? 0.28 : 0.85
                                    Behavior on opacity { NumberAnimation { duration: 250 } }
                                }

                                // arms + legs: the grey layer always sits underneath; the
                                // red one fades in on top when that group has been worked.
                                Repeater {
                                    model: ["arm_l", "arm_r", "legs"]
                                    delegate: Item {
                                        required property var modelData
                                        anchors.fill: parent
                                        opacity: window.restMode ? 0.25 : 0.9
                                        Behavior on opacity { NumberAnimation { duration: 250 } }
                                        Image {
                                            anchors.fill: parent
                                            source: "circ_" + parent.modelData + "_grey.png"
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true; asynchronous: true
                                            sourceSize.width: 479; sourceSize.height: 483
                                        }
                                        Image {
                                            anchors.fill: parent
                                            source: "circ_" + parent.modelData + "_red.png"
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true; asynchronous: true
                                            sourceSize.width: 479; sourceSize.height: 483
                                            opacity: anatomy.limbFresh(parent.modelData)
                                            Behavior on opacity { NumberAnimation { duration: 400 } }
                                        }
                                    }
                                }
                            }

                            // Stomach — upper-left abdomen (person's left = viewer's
                            // right, just above the navel); fills with the food goal.
                            // Declared AFTER the circulatory overlay so it sits IN FRONT
                            // of it and (with its opaque backdrop) hides the vessels
                            // behind it.
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
                            // fills with the water goal (PP). Declared AFTER the
                            // circulatory overlay so it sits IN FRONT of it.
                            Loader {
                                sourceComponent: organGaugeComponent
                                anchors.horizontalCenter: vitImg.horizontalCenter
                                anchors.verticalCenter: vitImg.verticalCenter
                                anchors.verticalCenterOffset: vitImg.paintedHeight * 0.025625
                                width: Math.max(1, vitImg.paintedHeight * 0.08)
                                height: Math.max(1, vitImg.paintedHeight * 0.075)
                                opacity: window.restMode ? 0.3 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }
                                onLoaded: {
                                    item.kind = "bladder";
                                    item.tint = Qt.binding(function () { return window.blue; });
                                    item.fillRatio = Qt.binding(function () { return window.st.vitals.ppMax > 0 ? window.st.vitals.pp / window.st.vitals.ppMax : 0; });
                                }
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

                            // ── AFFECT: Russell's circumplex, plotted IN the
                            // Vitruvian square. The square IS the Cartesian plane:
                            //   x = valence  (left unpleasant → right pleasant)
                            //   y = arousal  (bottom deactivated → top activated)
                            // Square bounds measured from the PNG's own line-art
                            // (105..857 × 179..939 of 958×966) so the dot tracks
                            // the drawn box exactly at any scale.
                            Item {
                                id: circumplex
                                anchors.centerIn: vitImg
                                width: Math.max(1, vitImg.paintedWidth)
                                height: Math.max(1, vitImg.paintedHeight)
                                opacity: window.restMode ? 0.25 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 250 } }

                                readonly property real sqLeft: 0.1096
                                readonly property real sqTop: 0.1853
                                readonly property real sqW: 0.7850
                                readonly property real sqH: 0.7867
                                readonly property var affect: window.affect
                                // −1..+1 → the square's pixel span.
                                readonly property real dotX: (sqLeft + (affect.valence + 1) / 2 * sqW) * width
                                readonly property real dotY: (sqTop + (1 - (affect.arousal + 1) / 2) * sqH) * height
                                readonly property color dotColor:
                                      affect.quadrant === "elated"   ? window.gold
                                    : affect.quadrant === "agitated" ? window.red
                                    : affect.quadrant === "flat"     ? window.overlay1
                                    :                                  window.teal

                                // Faint axes so the box reads as a plane.
                                Rectangle {
                                    x: circumplex.sqLeft * parent.width
                                    y: (circumplex.sqTop + circumplex.sqH / 2) * parent.height
                                    width: circumplex.sqW * parent.width; height: 1
                                    color: window.overlay0; opacity: 0.35
                                }
                                Rectangle {
                                    x: (circumplex.sqLeft + circumplex.sqW / 2) * parent.width
                                    y: circumplex.sqTop * parent.height
                                    width: 1; height: circumplex.sqH * parent.height
                                    color: window.overlay0; opacity: 0.35
                                }

                                // Soft halo — bigger when the reading is confident.
                                Rectangle {
                                    x: circumplex.dotX - width / 2
                                    y: circumplex.dotY - height / 2
                                    width: s(22); height: width; radius: width / 2
                                    color: circumplex.dotColor
                                    opacity: 0.16 * (0.5 + 0.5 * circumplex.affect.confidence)
                                    Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                                    Behavior on y { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                                    Behavior on color { ColorAnimation { duration: 400 } }
                                }
                                // The dot itself. Hollow while the reading is only
                                // an estimate; solid once the AI layer observes it.
                                Rectangle {
                                    id: affectDot
                                    x: circumplex.dotX - width / 2
                                    y: circumplex.dotY - height / 2
                                    width: s(9); height: width; radius: width / 2
                                    color: circumplex.affect.source === "observed" ? circumplex.dotColor : "transparent"
                                    border.color: circumplex.dotColor
                                    border.width: Math.max(1, s(1.5))
                                    Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                                    Behavior on y { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                                    Behavior on color { ColorAnimation { duration: 400 } }

                                    // Gentle breathing pulse, faster when activated.
                                    SequentialAnimation on scale {
                                        running: !window.restMode
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 1.18; duration: Math.round(1400 - 600 * (circumplex.affect.arousal + 1) / 2); easing.type: Easing.InOutSine }
                                        NumberAnimation { to: 1.0;  duration: Math.round(1400 - 600 * (circumplex.affect.arousal + 1) / 2); easing.type: Easing.InOutSine }
                                    }
                                }

                                // Quadrant name, tucked under the square's bottom edge.
                                Text {
                                    textFormat: Text.PlainText
                                    x: circumplex.sqLeft * parent.width
                                    y: (circumplex.sqTop + circumplex.sqH) * parent.height + s(3)
                                    text: circumplex.affect.name.toUpperCase()
                                        + (circumplex.affect.source === "estimated" ? " ~" : "")
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold
                                    font.pixelSize: s(8); font.letterSpacing: s(1)
                                    color: circumplex.dotColor
                                    opacity: 0.85
                                }
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
                                    Text { textFormat: Text.PlainText; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: s(11); color: window.subtext0 }
                                    Text { textFormat: Text.PlainText; text: "Back"; font.family: "JetBrains Mono"; font.pixelSize: s(10); color: window.subtext0 }
                                }
                            }
                            Text {
                                textFormat: Text.PlainText
                                text: detailView.summ ? detailView.summ.glyph + "  " + detailView.summ.name : ""
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(14); color: window.text
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                textFormat: Text.PlainText
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
                                textFormat: Text.PlainText
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
                                            textFormat: Text.PlainText
                                            text: modelData.name
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: s(10); color: window.red
                                        }
                                        Text {
                                            textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    text: window.dangerAll.length > 0
                        ? ("  " + window.dangerAll.length + " danger zone" + (window.dangerAll.length === 1 ? "" : "s") + " active")
                        : "  no danger zones"
                    font.family: "JetBrains Mono"; font.pixelSize: s(9)
                    color: window.dangerAll.length > 0 ? window.red : window.overlay0
                }
                Item { Layout.fillWidth: true }
                Text {
                    textFormat: Text.PlainText
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
