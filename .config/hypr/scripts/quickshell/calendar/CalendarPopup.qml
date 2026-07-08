import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtCore
import Quickshell
import Quickshell.Io
import QtQuick.Window
import "../"

Item {
    id: window

    // Main.qml passes these to every widget it creates/reopens; unused here but
    // declared so the assignments don't raise "non-existent property" errors.
    property var notifModel
    property var liveNotifs
    property real layoutWidth: 0
    property real layoutHeight: 0

    Caching { id: paths }

    // --- Responsive Scaling Logic ---
    Scaler {
        id: scaler
        // Pass both width and height so the internal popup scale perfectly synchronizes
        // with the master window's WindowRegistry.js calculations
        currentWidth: Screen.width
        currentHeight: Screen.height
    }
    
    // Expose reactive scale factor for all bindings
    readonly property real sf: scaler.baseScale

    // Keep helper function for backwards compatibility in pure JS blocks
    function s(val) { 
        return Math.round(val * window.sf); 
    }

    // -------------------------------------------------------------------------
    // DYNAMIC MASTER WINDOW SCALING (Fixes Window Clipping)
    // -------------------------------------------------------------------------
    property real targetMasterHeight: window.newsReaderOpen ? Math.round(860 * window.sf)
        : (window.scheduleModuleExists ? Math.round(750 * window.sf) : Math.round(510 * window.sf))
    property real targetMasterWidth: Math.round(1450 * window.sf)
    
    onTargetMasterHeightChanged: {
        if (typeof masterWindow !== "undefined") {
            masterWindow.animH = window.targetMasterHeight;
            masterWindow.targetH = window.targetMasterHeight;
        }
    }

    onTargetMasterWidthChanged: {
        if (typeof masterWindow !== "undefined") {
            masterWindow.animW = window.targetMasterWidth;
            masterWindow.targetW = window.targetMasterWidth;
            
            // Re-center horizontally to keep the popup perfectly in the middle when scaling changes
            let newX = Math.floor((Screen.width / 2) - (window.targetMasterWidth / 2));
            if (masterWindow.targetX !== undefined) masterWindow.targetX = newX;
            masterWindow.animX = newX;
        }
    }

    // -------------------------------------------------------------------------
    // KEYBOARD SHORTCUTS
    // (Escape is handled by Main.qml now)
    // -------------------------------------------------------------------------
    Shortcut { 
        sequence: "Left"
        onActivated: {
            if (calHover.hovered) {
                window.setMonthOffset(window.targetMonthOffset - 1);
            } else {
                window.setWeatherView(window.targetWeatherView - 1);
            }
        }
    }

    Shortcut { 
        sequence: "Right"
        onActivated: {
            if (calHover.hovered) {
                window.setMonthOffset(window.targetMonthOffset + 1);
            } else {
                window.setWeatherView(window.targetWeatherView + 1);
            }
        }
    }

    // -------------------------------------------------------------------------
    // COLORS (Dynamic Matugen Palette)
    // -------------------------------------------------------------------------
    MatugenColors { id: _theme }
    readonly property color base: _theme.base
    readonly property color mantle: _theme.mantle
    readonly property color crust: _theme.crust
    readonly property color text: _theme.text
    readonly property color subtext1: _theme.subtext1
    readonly property color subtext0: _theme.subtext0
    readonly property color overlay2: _theme.overlay2
    readonly property color overlay1: _theme.overlay1
    readonly property color overlay0: _theme.overlay0
    readonly property color surface2: _theme.surface2
    readonly property color surface1: _theme.surface1
    readonly property color surface0: _theme.surface0
    
    readonly property color mauve: _theme.mauve
    readonly property color pink: _theme.pink
    readonly property color blue: _theme.blue
    readonly property color sapphire: _theme.sapphire
    readonly property color peach: _theme.peach
    readonly property color yellow: _theme.yellow
    readonly property color teal: _theme.teal
    readonly property color green: _theme.green
    readonly property color red: _theme.red

    readonly property string scriptsDir: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/calendar"

    // -------------------------------------------------------------------------
    // TIME OF DAY DYNAMIC COLORS
    // -------------------------------------------------------------------------
    // Keyed off an int that only CHANGES once an hour — binding directly to
    // currentTime made every accent-coloured element re-evaluate each second.
    readonly property int currentHour: currentTime.getHours()

    readonly property color timeColor: {
        let h = window.currentHour;
        if (h >= 5 && h < 12) return window.peach;      // Morning
        if (h >= 12 && h < 17) return window.sapphire;  // Afternoon
        if (h >= 17 && h < 21) return window.mauve;     // Evening
        return window.blue;                             // Night
    }

    readonly property color timeAccent: {
        let h = window.currentHour;
        if (h >= 5 && h < 12) return window.yellow;     // Morning Accent
        if (h >= 12 && h < 17) return window.teal;      // Afternoon Accent
        if (h >= 17 && h < 21) return window.pink;      // Evening Accent
        return window.mauve;                            // Night Accent
    }

    readonly property color textAccent: Qt.tint(window.timeAccent, Qt.alpha(window.text, 0.35))

    // -------------------------------------------------------------------------
    // STARTUP ANIMATION STATES
    // -------------------------------------------------------------------------
    property bool startupComplete: false
    property real introMain: 0
    property real introAmbient: 0
    property real introClock: 0
    property real introCalendar: 0
    property real introWeather: 0
    property real introSchedule: 0

    SequentialAnimation {
        running: true
        
        // 50ms buffer to allow the window manager to map the surface before animating
        PauseAnimation { duration: 20 }

        ParallelAnimation {
            // Base window fades and scales slightly
            NumberAnimation { target: window; property: "introMain"; from: 0; to: 1.0; duration: 800; easing.type: Easing.OutQuart }

            // Ambient background glows and big parallax icon fade in
            SequentialAnimation {
                PauseAnimation { duration: 150 }
                NumberAnimation { target: window; property: "introAmbient"; from: 0; to: 1.0; duration: 1000; easing.type: Easing.OutSine }
            }

            // Central clock and 3D orbital pop from the center
            SequentialAnimation {
                PauseAnimation { duration: 250 }
                NumberAnimation { target: window; property: "introClock"; from: 0; to: 1.0; duration: 900; easing.type: Easing.OutBack; easing.overshoot: 1.15 }
            }

            // Left wing (Calendar) slides in from the left
            SequentialAnimation {
                PauseAnimation { duration: 350 }
                NumberAnimation { target: window; property: "introCalendar"; from: 0; to: 1.0; duration: 850; easing.type: Easing.OutQuint }
            }

            // Right wing (Weather) slides in from the right
            SequentialAnimation {
                PauseAnimation { duration: 400 }
                NumberAnimation { target: window; property: "introWeather"; from: 0; to: 1.0; duration: 850; easing.type: Easing.OutQuint }
            }

            // Bottom section (Schedule) flows up smoothly
            SequentialAnimation {
                PauseAnimation { duration: 500 }
                NumberAnimation { target: window; property: "introSchedule"; from: 0; to: 1.0; duration: 900; easing.type: Easing.OutExpo }
            }
        }
        ScriptAction { script: window.startupComplete = true }
    }

    ParallelAnimation {
        id: exitAnim
        NumberAnimation { target: window; property: "introMain"; to: 0; duration: 400; easing.type: Easing.InQuart }
        NumberAnimation { target: window; property: "introAmbient"; to: 0; duration: 250; easing.type: Easing.InQuart }
        NumberAnimation { target: window; property: "introClock"; to: 0; duration: 300; easing.type: Easing.InQuart }
        NumberAnimation { target: window; property: "introCalendar"; to: 0; duration: 350; easing.type: Easing.InQuart }
        NumberAnimation { target: window; property: "introWeather"; to: 0; duration: 350; easing.type: Easing.InQuart }
        NumberAnimation { target: window; property: "introSchedule"; to: 0; duration: 200; easing.type: Easing.InQuart }
    }

    // ── Shared ambient clock ────────────────────────────────────────────────
    // Every continuous "alive" motion (orbit, blob drift, hub levitation and
    // 3D wobble, arrow nudges, the clock's second pulse) used to be its own
    // per-frame NumberAnimation — together they kept the 144Hz render loop
    // awake 100% of the time (~10% of a core) and two of them (drift,
    // levitation) had no `running` gate, so they animated even while this
    // widget sat hidden in Main.qml's forever-cache (another ~10%).
    // One 50ms wall-clock-accurate timer now advances `ambientPhase`; each
    // motion is an exact-waveform sin/cos binding of it. The largest of these
    // motions moves well under a pixel per 50ms step, so 20fps sampling is
    // visually identical.
    property real ambientPhase: 0
    property real _ambientLast: 0
    Timer {
        interval: 50; repeat: true; running: window.visible
        onTriggered: {
            var n = Date.now();
            if (window._ambientLast > 0) window.ambientPhase += Math.min(200, n - window._ambientLast);
            window._ambientLast = n;
        }
        onRunningChanged: window._ambientLast = 0
    }
    readonly property real globalOrbitAngle: (ambientPhase % 90000) / 90000 * Math.PI * 2

    // -------------------------------------------------------------------------
    // STATE & TIME (WITH SECOND PULSE)
    // -------------------------------------------------------------------------
    property var currentTime: new Date()
    property real currentEpoch: currentTime.getTime() / 1000
    
    // Second pulse: 1.06 → 1.0 over 600ms with the exact OutQuint curve the old
    // per-frame NumberAnimation produced (v = 1 + 0.06·(1-t)^5), sampled by the
    // shared 20fps ambient clock instead of running its own animation every second.
    property real pulseT0: -600
    readonly property real secondPulse: {
        var t = Math.min(1, Math.max(0, (ambientPhase - pulseT0) / 600));
        return 1.0 + 0.06 * Math.pow(1 - t, 5);
    }

    // Day stamp the calendar grid was last built for — rebuilt when it goes
    // stale (at midnight OR on the first tick after reopening past midnight;
    // the old exact ==00:00:00 comparison could miss the tick entirely).
    property string gridDayStamp: ""

    Timer {
        interval: 1000; running: window.visible; repeat: true
        onTriggered: {
            window.currentTime = new Date();
            window.pulseT0 = window.ambientPhase; // Gentle pulse

            if (window.currentTime.toDateString() !== window.gridDayStamp) {
                updateCalendarGrid();
            }
        }
    }

    // -------------------------------------------------------------------------
    // WEATHER DATA & ELEGANT TRANSITIONS (3D ORBIT SPIN)
    // -------------------------------------------------------------------------
    property var weatherData: null
    property int weatherView: 0
    property color activeWeatherHex: {
        if (!window.weatherData) return window.mauve;
        if (window.weatherView === 0 && window.weatherData.current_hex) return window.weatherData.current_hex;
        if (window.weatherData.forecast && window.weatherData.forecast[window.weatherView]) return window.weatherData.forecast[window.weatherView].hex;
        return window.mauve;
    }

    // Transition Properties
    property int targetWeatherView: 0
    property real weatherContentOpacity: 1.0
    property real weatherContentOffset: 0.0
    property int weatherAnimDirection: 1
    
    // New 3D Spin Properties
    property real transitionSpin: 0.0
    property real transitionScale: 1.0

    // -------------------------------------------------------------------------
    // TEMPERATURE LOGIC 
    // -------------------------------------------------------------------------
    property real targetTemp: {
        if (!window.weatherData) return 0;
        if (window.targetWeatherView === 0 && window.weatherData.current_temp !== undefined) {
            return Number(window.weatherData.current_temp);
        }
        if (window.weatherData.forecast && window.weatherData.forecast[window.targetWeatherView]) {
            return Number(window.weatherData.forecast[window.targetWeatherView].max);
        }
        return 0;
    }
    
    property real displayedTemp: targetTemp

    Behavior on displayedTemp {
        NumberAnimation {
            id: tempAnim
            duration: 800
            easing.type: Easing.OutQuart
        }
    }

    property bool isTempAnimating: tempAnim.running
    property color tempGlowColor: {
        if (!isTempAnimating || !window.startupComplete) return window.text;
        
        // If the target is higher than the currently ticking number, we are counting up
        if (window.targetTemp > window.displayedTemp) return window.red;
        
        // If the target is lower than the currently ticking number, we are counting down
        if (window.targetTemp < window.displayedTemp) return window.blue;
        
        return window.text; 
    }

    SequentialAnimation {
        id: weatherTransitionAnim
        ParallelAnimation {
            NumberAnimation { target: window; property: "weatherContentOpacity"; to: 0.0; duration: 250; easing.type: Easing.InSine }
            NumberAnimation { target: window; property: "weatherContentOffset"; to: Math.round(-40 * window.sf) * weatherAnimDirection; duration: 250; easing.type: Easing.InSine }
            
            // Spin the 3D orbit out and scale it down for depth
            NumberAnimation { target: window; property: "transitionSpin"; to: 180 * weatherAnimDirection; duration: 300; easing.type: Easing.InBack }
            NumberAnimation { target: window; property: "transitionScale"; to: 0.8; duration: 300; easing.type: Easing.InCubic }
        }
        ScriptAction { 
            script: { 
                window.weatherView = window.targetWeatherView; 
                window.weatherContentOffset = Math.round(40 * window.sf) * weatherAnimDirection; // Move to opposite side while hidden
                
                // Reset the spin to the opposite side so it continues spinning into place seamlessly
                window.transitionSpin = -180 * weatherAnimDirection;
            } 
        }
        ParallelAnimation {
            NumberAnimation { target: window; property: "weatherContentOpacity"; to: 1.0; duration: 450; easing.type: Easing.OutQuart }
            NumberAnimation { target: window; property: "weatherContentOffset"; to: 0.0; duration: 450; easing.type: Easing.OutQuart }
            
            // Snap the 3D orbit back to 0 degrees and restore full scale
            NumberAnimation { target: window; property: "transitionSpin"; to: 0.0; duration: 600; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
            NumberAnimation { target: window; property: "transitionScale"; to: 1.0; duration: 500; easing.type: Easing.OutBack }
        }
    }

    function setWeatherView(idx) {
        if (idx < 0 || idx > 4 || !window.weatherData) return;
        if (idx === window.targetWeatherView) return; // Ignore if we are already heading there

        // If an animation is already running, gracefully interrupt it and apply the logical switch
        // before starting the new animation so the data doesn't get desynced.
        if (weatherTransitionAnim.running) {
            weatherTransitionAnim.stop();
            window.weatherView = window.targetWeatherView;
        }

        window.weatherAnimDirection = idx > window.weatherView ? 1 : -1;
        window.targetWeatherView = idx;
        weatherTransitionAnim.start();
    }

    property int activeHourIndex: {
        if (window.weatherView !== 0 || !window.weatherData || !window.weatherData.forecast || !window.weatherData.forecast[0] || !window.weatherData.forecast[0].hourly) return -1;
        
        let ch = window.currentTime.getHours();
        let hrArr = window.weatherData.forecast[0].hourly.slice(0, 8);
        let bestIdx = -1;
        let minDiff = 999;
        
        for (let i = 0; i < hrArr.length; i++) {
            let timeStr = hrArr[i].time || "00:00";
            let h = parseInt(timeStr.split(":")[0]);
            let diff = Math.abs(h - ch);
            if (diff < minDiff) {
                minDiff = diff;
                bestIdx = i;
            }
        }
        return bestIdx !== -1 ? bestIdx : 0;
    }

    Process {
        id: weatherPoller
        command: ["bash", window.scriptsDir + "/weather.sh", "--json"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text.trim();
                if (txt !== "") {
                    try { window.weatherData = JSON.parse(txt); } catch(e) {}
                }
            }
        }
    }

    Timer {
        interval: 150000
        running: window.visible; repeat: true
        onTriggered: weatherPoller.running = true
    }

    // ── News feed (native) — reads ~/.cache/qs_news.json written by news_fetch.py ──
    property var newsData: null
    readonly property var newsItems: (newsData && newsData.items) ? newsData.items : []
    property bool newsReaderOpen: false
    property int newsReaderIndex: 0
    readonly property var newsCurrent: (newsReaderIndex >= 0 && newsItems.length > newsReaderIndex) ? newsItems[newsReaderIndex] : null

    // Compact relative time for the card/list (e.g. "3h ago").
    function newsAgo(ts) {
        if (!ts) return "";
        var d = Math.max(0, Math.floor(Date.now() / 1000) - ts);
        if (d < 3600) return Math.floor(d / 60) + "m ago";
        if (d < 86400) return Math.floor(d / 3600) + "h ago";
        return Math.floor(d / 86400) + "d ago";
    }

    Process {
        id: newsPoller
        command: ["bash", "-c", "cat \"${XDG_CACHE_HOME:-$HOME/.cache}/qs_news.json\" 2>/dev/null"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text.trim();
                if (txt !== "") { try { window.newsData = JSON.parse(txt); } catch(e) {} }
            }
        }
    }
    Timer {
        interval: 120000
        running: window.visible; repeat: true
        onTriggered: newsPoller.running = true
    }
    // Refresh the cache read each time the popup is shown, for snappy first paint.
    Connections {
        target: window
        function onVisibleChanged() {
            if (window.visible) newsPoller.running = true;
            else window.clearSelectedDay();   // reopen always starts in weather mode
        }
    }

    // -------------------------------------------------------------------------
    // SCHEDULE DATA & CONDITIONAL RENDERING
    // -------------------------------------------------------------------------
    property bool scheduleModuleExists: false
    property var scheduleData: { "header": "Loading Schedule...", "link": "", "lessons": [] }

    // Dynamic offset based on whether the schedule module exists
    property real centerOffset: window.scheduleModuleExists ? Math.round(-100 * window.sf) : Math.round(50 * window.sf)
    Behavior on centerOffset { NumberAnimation { duration: 600; easing.type: Easing.OutQuart } }

    // Check if the schedule manager script actually exists before doing anything
    Process {
        id: schedulePathChecker
        command: ["bash", "-c", "[ -f '" + window.scriptsDir + "/schedule/schedule_manager.sh' ] && echo 1 || echo 0"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                if (this.text.trim() === "1") {
                    window.scheduleModuleExists = true;
                    schedulePoller.running = true; // Safe to start polling
                } else {
                    window.scheduleModuleExists = false;
                    // Shrinking is now automatically handled by the onTargetMasterHeightChanged watcher
                }
            }
        }
    }

    Process {
        id: schedulePoller
        command: ["bash", window.scriptsDir + "/schedule/schedule_manager.sh"]
        running: false // Handled by schedulePathChecker
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text.trim();
                if (txt !== "") {
                    try { window.scheduleData = JSON.parse(txt); } catch(e) { console.log("Schedule Parse Error:", e); }
                }
            }
        }
    }

    Timer {
        interval: 600000 
        // Only run the timer if the module actually exists
        running: window.scheduleModuleExists && window.visible; repeat: true
        onTriggered: schedulePoller.running = true
    }

    // -------------------------------------------------------------------------
    // CALENDAR GRID LOGIC & TRANSITIONS
    // -------------------------------------------------------------------------
    // ── SYSTEM CALENDAR (vdir ~/.calendars, standard iCalendar files) ──────
    // Clicking a date in the month grid swaps the hourly weather orbit for an
    // hourly appointments view of that day (click the same date again to
    // return). events.py reads/writes the same store khal/vdirsyncer use.
    property string selectedDayIso: ""          // "" = weather mode
    property string selectedDayLabel: ""
    property int selectedDayNum: -1
    property int selectedDayMonthOffset: 0
    property var dayEvents: []
    property bool dayEventsLoading: false

    Process {
        id: eventsFetcher
        command: ["python3", window.scriptsDir + "/events.py", "list", window.selectedDayIso]
        stdout: StdioCollector {
            onStreamFinished: {
                window.dayEventsLoading = false;
                try { window.dayEvents = JSON.parse(this.text); } catch(e) { window.dayEvents = []; }
            }
        }
    }

    function displayedMonthBase() {
        let d = new Date();
        d.setDate(1);
        d.setMonth(d.getMonth() + window.monthOffset);
        return d;
    }

    function selectDay(dayNumStr) {
        let dn = parseInt(dayNumStr);
        let base = displayedMonthBase();
        let y = base.getFullYear(), m = base.getMonth() + 1;
        let iso = y + "-" + (m < 10 ? "0" : "") + m + "-" + (dn < 10 ? "0" : "") + dn;
        if (window.selectedDayIso === iso) { window.clearSelectedDay(); return; }
        let full = new Date(y, m - 1, dn);
        window.selectedDayLabel = Qt.formatDate(full, "dddd, MMMM dd");
        window.selectedDayNum = dn;
        window.selectedDayMonthOffset = window.monthOffset;
        window.selectedDayIso = iso;
        window.dayEvents = [];
        window.dayEventsLoading = true;
        eventsFetcher.running = false; eventsFetcher.running = true;
    }

    function clearSelectedDay() {
        window.selectedDayIso = "";
        window.selectedDayLabel = "";
        window.selectedDayNum = -1;
        window.dayEvents = [];
        window.dayEventsLoading = false;
    }

    property int monthOffset: 0
    property int targetMonthOffset: 0
    property string targetMonthName: ""
    ListModel { id: calendarModel }

    property real calendarContentOpacity: 1.0
    property real calendarContentOffset: 0.0
    property int calendarAnimDirection: 1

    SequentialAnimation {
        id: calendarTransitionAnim
        ParallelAnimation {
            NumberAnimation { target: window; property: "calendarContentOpacity"; to: 0.0; duration: 200; easing.type: Easing.InSine }
            NumberAnimation { target: window; property: "calendarContentOffset"; to: Math.round(-20 * window.sf) * calendarAnimDirection; duration: 200; easing.type: Easing.InSine }
        }
        ScriptAction {
            script: {
                window.monthOffset = window.targetMonthOffset;
                window.calendarContentOffset = Math.round(20 * window.sf) * calendarAnimDirection;
            }
        }
        ParallelAnimation {
            NumberAnimation { target: window; property: "calendarContentOpacity"; to: 1.0; duration: 350; easing.type: Easing.OutQuart }
            NumberAnimation { target: window; property: "calendarContentOffset"; to: 0.0; duration: 350; easing.type: Easing.OutQuart }
        }
    }

    function setMonthOffset(newOffset) {
        if (newOffset === window.targetMonthOffset) return;

        if (calendarTransitionAnim.running) {
            calendarTransitionAnim.stop();
            window.monthOffset = window.targetMonthOffset;
        }

        window.calendarAnimDirection = newOffset > window.targetMonthOffset ? 1 : -1;
        window.targetMonthOffset = newOffset;
        calendarTransitionAnim.start();
    }

    function updateCalendarGrid() {
        let d = new Date(window.currentTime.getTime());
        d.setDate(1); 
        d.setMonth(d.getMonth() + window.monthOffset);

        let targetMonth = d.getMonth();
        let targetYear = d.getFullYear();
        
        let actualToday = new Date();
        let isRealCurrentMonth = (actualToday.getMonth() === targetMonth && actualToday.getFullYear() === targetYear);
        let todayDate = actualToday.getDate();
        window.gridDayStamp = actualToday.toDateString();

        window.targetMonthName = Qt.formatDateTime(d, "MMMM yyyy");

        let firstDay = new Date(targetYear, targetMonth, 1).getDay();
        firstDay = (firstDay === 0) ? 6 : firstDay - 1; 

        let daysInMonth = new Date(targetYear, targetMonth + 1, 0).getDate();
        let daysInPrevMonth = new Date(targetYear, targetMonth, 0).getDate();

        calendarModel.clear();

        for (let i = firstDay - 1; i >= 0; i--) {
            calendarModel.append({ dayNum: (daysInPrevMonth - i).toString(), isCurrentMonth: false, isToday: false });
        }
        for (let i = 1; i <= daysInMonth; i++) {
            calendarModel.append({ dayNum: i.toString(), isCurrentMonth: true, isToday: (isRealCurrentMonth && i === todayDate) });
        }
        let remaining = 42 - calendarModel.count;
        for (let i = 1; i <= remaining; i++) {
            calendarModel.append({ dayNum: i.toString(), isCurrentMonth: false, isToday: false });
        }
    }

    onMonthOffsetChanged: updateCalendarGrid()

    Component.onCompleted: {
        updateCalendarGrid();
    }

    // -------------------------------------------------------------------------
    // UI LAYOUT
    // -------------------------------------------------------------------------
    Item {
        anchors.fill: parent
        scale: 0.95 + (0.05 * introMain)
        opacity: introMain

        Rectangle {
            anchors.fill: parent
            radius: Math.round(20 * window.sf)
            color: window.base
            border.color: window.surface0
            border.width: 1
            clip: true

            // =======================================================
            // AMBIENT WIDGET COLOR BLOBS (Spread Out)
            // =======================================================
            Rectangle {
                width: parent.width * 0.5; height: width; radius: width / 2
                x: (parent.width * 0.75 - width / 2) + Math.cos(window.globalOrbitAngle * 1.5) * Math.round(350 * window.sf)
                y: (parent.height * 0.3 - height / 2) + Math.sin(window.globalOrbitAngle * 1.5) * Math.round(200 * window.sf)
                opacity: 0.025 * window.introAmbient
                color: window.activeWeatherHex
                Behavior on color { ColorAnimation { duration: 1000 } }
            }

            Rectangle {
                width: parent.width * 0.6; height: width; radius: width / 2
                x: (parent.width * 0.25 - width / 2) + Math.sin(window.globalOrbitAngle * 1.2) * Math.round(-300 * window.sf)
                y: (parent.height * 0.7 - height / 2) + Math.cos(window.globalOrbitAngle * 1.2) * Math.round(-250 * window.sf)
                opacity: 0.02 * window.introAmbient
                color: window.timeColor
                Behavior on color { ColorAnimation { duration: 1000 } }
            }

            Rectangle {
                width: parent.width * 0.45; height: width; radius: width / 2
                x: (parent.width * 0.5 - width / 2) + Math.cos(window.globalOrbitAngle * -1.8) * Math.round(400 * window.sf)
                y: (parent.height * 0.5 - height / 2) + Math.sin(window.globalOrbitAngle * -1.8) * Math.round(-350 * window.sf)
                opacity: 0.015 * window.introAmbient
                color: window.timeAccent
                Behavior on color { ColorAnimation { duration: 1000 } }
            }

            // Big Parallax Weather Icon (Tied to Weather Transition)
            Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: window.centerOffset
                text: {
                    if (!window.weatherData) return "";
                    if (window.weatherView === 0 && window.weatherData.current_icon) return window.weatherData.current_icon;
                    if (window.weatherData.forecast && window.weatherData.forecast[window.weatherView]) return window.weatherData.forecast[window.weatherView].icon;
                    return "";
                }
                font.family: "Iosevka Nerd Font"
                font.pixelSize: Math.round(800 * window.sf)
                color: window.activeWeatherHex
                opacity: (0.03 + (0.01 * Math.sin(window.globalOrbitAngle * 4))) * window.introAmbient * window.weatherContentOpacity
                z: 0
                Behavior on color { ColorAnimation { duration: 1500 } }
                
                // 0 → -20sf → 0 over 12s (two InOutSine halves = one cosine period),
                // driven by the shared ambient clock. The old standalone animation
                // additionally had no `running` gate, so it ran while hidden.
                readonly property real drift: Math.round(-20 * window.sf) * (1 - Math.cos(2 * Math.PI * window.ambientPhase / 12000)) / 2
                
                transform: [
                    Translate { y: parent ? parent.drift : 0 },
                    Translate { x: window.weatherContentOffset * 2 } // Exaggerated shift for background depth
                ]
            }

            // News module — a full-height panel on the right listing headlines
            // (native, from qs_news.json). Click a row → the taller in-place reader.
            Rectangle {
                id: newsCard
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: Math.round(24 * window.sf)
                // 320 (mirrors the calendar) keeps the panel's left edge clear of the
                // hourly-orbit ring + cards; wider (e.g. 380) clips the circle on the right.
                width: Math.round(320 * window.sf)
                radius: Math.round(14 * window.sf)
                color: Qt.alpha(window.surface0, 0.2)
                border.color: Qt.alpha(window.surface1, 0.4)
                border.width: 1
                opacity: window.introWeather
                z: 6

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Math.round(14 * window.sf)
                    spacing: Math.round(10 * window.sf)

                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "News"; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: Math.round(18 * window.sf); color: window.text }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: window.newsItems.length > 0 ? (window.newsItems.length + " stories") : ""
                            font.family: "JetBrains Mono"; font.pixelSize: Math.round(10 * window.sf); color: window.overlay1
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: window.newsItems.length === 0
                        text: "No headlines yet — add feeds in FreshRSS."
                        font.family: "JetBrains Mono"; font.pixelSize: Math.round(11 * window.sf); color: window.overlay1; wrapMode: Text.Wrap
                    }

                    ListView {
                        id: newsModuleList
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true; spacing: Math.round(6 * window.sf)
                        visible: window.newsItems.length > 0
                        model: window.newsItems

                        delegate: Rectangle {
                            width: ListView.view.width
                            height: Math.round(72 * window.sf)
                            radius: Math.round(10 * window.sf)
                            color: rowMa2.containsMouse ? Qt.alpha(window.surface1, 0.45) : Qt.alpha(window.surface0, 0.35)
                            Behavior on color { ColorAnimation { duration: 120 } }

                            RowLayout {
                                anchors.fill: parent; anchors.margins: Math.round(7 * window.sf); spacing: Math.round(8 * window.sf)
                                Rectangle {
                                    Layout.preferredWidth: Math.round(58 * window.sf); Layout.preferredHeight: Math.round(58 * window.sf)
                                    Layout.alignment: Qt.AlignVCenter
                                    radius: Math.round(8 * window.sf); clip: true; color: Qt.alpha(window.surface1, 0.5)
                                    visible: modelData.image
                                    Image { anchors.fill: parent; source: modelData.image || ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: Math.round(116 * window.sf); sourceSize.height: Math.round(116 * window.sf) }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; spacing: Math.round(2 * window.sf)
                                    Text { Layout.fillWidth: true; text: (modelData.source || "") + "  ·  " + window.newsAgo(modelData.ts); textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(8 * window.sf); color: window.textAccent; elide: Text.ElideRight }
                                    Text { Layout.fillWidth: true; text: modelData.title || ""; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: Math.round(11 * window.sf); color: window.text; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                }
                            }
                            MouseArea { id: rowMa2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { window.newsReaderIndex = index; window.newsReaderOpen = true; } }
                        }
                    }
                }
            }

            // =======================================================
            // CENTRAL HERO: THE BREATHING TIME HUB & 3D HOURLY ORBIT
            // =======================================================
            Item {
                id: centralHub
                anchors.centerIn: parent
                anchors.verticalCenterOffset: window.centerOffset
                width: Math.round(1 * window.sf); height: Math.round(1 * window.sf)
                z: 5

                // The whole hub (clock + orbit) yields to the day view while a
                // calendar date is selected.
                visible: window.selectedDayIso === ""

                opacity: introClock
                scale: 0.85 + (0.15 * introClock)

                // All hub motion comes from the shared ambient clock: the two
                // InOutSine halves of each old SequentialAnimation compose into
                // one pure sinusoid, reproduced exactly below (the ±wobbles use
                // sin so they still start from 0 like the originals did).
                readonly property real levitation: Math.round(-15 * window.sf) * (1 - Math.cos(2 * Math.PI * window.ambientPhase / 8000)) / 2
                readonly property real orbitBreath: 1.0 + 0.035 * (1 - Math.cos(2 * Math.PI * window.ambientPhase / 7000)) / 2

                // 3D Perspective Wobble (Pitch, Yaw, Roll)
                readonly property real pitchBreath: 3.5 * Math.sin(2 * Math.PI * window.ambientPhase / 8400)
                readonly property real yawBreath: 2.5 * Math.sin(2 * Math.PI * window.ambientPhase / 10200)
                readonly property real rollBreath: 1.5 * Math.sin(2 * Math.PI * window.ambientPhase / 11600)
                
                transform: [
                    Translate { y: Math.round(25 * window.sf) * (1.0 - introClock) },
                    Translate { y: centralHub.levitation },
                    Rotation { axis { x: 1; y: 0; z: 0 } angle: centralHub.pitchBreath },
                    Rotation { axis { x: 0; y: 1; z: 0 } angle: centralHub.yawBreath },
                    Rotation { axis { x: 0; y: 0; z: 1 } angle: centralHub.rollBreath }
                ]

                // OPTIMIZATION: Moved scale property out of the onPaint function to prevent redrawing every frame.
                // It now draws once, and scales using the GPU.
                Canvas {
                    id: orbitCanvas
                    z: -10
                    x: Math.round(-400 * window.sf)   // Widened to prevent clipping when scaled
                    y: Math.round(-200 * window.sf)   // Heightened to prevent clipping when scaled
                    width: Math.round(800 * window.sf)
                    height: Math.round(400 * window.sf)
                    opacity: 0.25

                    scale: centralHub.orbitBreath

                    onWidthChanged: requestPaint()
                    // The dashed ellipse strokes with textAccent; without this it kept
                    // the colour it was first painted with until a resize forced a
                    // repaint (stale across time-of-day and palette changes).
                    property color accent: window.textAccent
                    onAccentChanged: requestPaint()

                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.beginPath();
                        var currentRx = Math.round(320 * window.sf);
                        var currentRy = Math.round(140 * window.sf);
                        for (var i = 0; i <= Math.PI * 2; i += 0.05) {
                            var xx = width/2 + Math.cos(i) * currentRx;
                            var yy = height/2 + Math.sin(i) * currentRy;
                            if (i === 0) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy);
                        }
                        ctx.strokeStyle = window.textAccent;
                        ctx.lineWidth = Math.max(1, Math.round(1.5 * window.sf));
                        ctx.setLineDash([Math.round(4 * window.sf), Math.round(10 * window.sf)]);
                        ctx.stroke();
                    }
                    Behavior on opacity { NumberAnimation { duration: 1500 } }
                }

                // Core Clock
                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 0
                    z: 0 
                    scale: 0.95 + (0.05 * window.secondPulse) 
                    
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: Math.round(2 * window.sf)
                        Text {
                            text: Qt.formatTime(window.currentTime, "HH:mm")
                            font.family: "JetBrains Mono"
                            font.weight: Font.Black
                            font.pixelSize: Math.round(84 * window.sf)
                            color: window.text
                            style: Text.Outline; styleColor: Qt.alpha(window.crust, 0.4)
                        }
                        Text {
                            text: Qt.formatTime(window.currentTime, ":ss")
                            font.family: "JetBrains Mono"
                            font.weight: Font.Bold
                            font.pixelSize: Math.round(32 * window.sf)
                            color: window.textAccent
                            Layout.alignment: Qt.AlignBottom
                            Layout.bottomMargin: Math.round(15 * window.sf)
                            opacity: window.secondPulse > 1.02 ? 1.0 : 0.6 
                            style: Text.Outline; styleColor: Qt.alpha(window.crust, 0.4)
                            Behavior on color { ColorAnimation { duration: 1000 } }
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: Qt.formatDateTime(window.currentTime, "dddd, MMMM dd")
                        font.family: "JetBrains Mono"
                        font.weight: Font.Bold
                        font.pixelSize: Math.round(16 * window.sf)
                        color: window.subtext0
                        opacity: 0.9
                    }
                }

                // TRUE 3D ORBITAL HOURLY FORECAST (Tied to Spin Transition)
                Item {
                    anchors.fill: parent
                    opacity: window.weatherContentOpacity

                    // Added Scale property to give a z-depth shrink effect when spinning
                    scale: window.transitionScale
                    transform: Translate { x: window.weatherContentOffset * 1.5 }

                    Repeater {
                        id: hourRepeater
                        model: window.weatherData && window.weatherData.forecast[window.weatherView] && window.weatherData.forecast[window.weatherView].hourly ? window.weatherData.forecast[window.weatherView].hourly.slice(0, 8) : []
                        
                        delegate: Item {
                            property int mCount: hourRepeater.count
                            property bool isToday: window.weatherView === 0
                            property bool isHighlighted: isToday && index === window.activeHourIndex
                            
                            property real rx: Math.round(320 * window.sf) * centralHub.orbitBreath
                            property real ry: Math.round(140 * window.sf) * centralHub.orbitBreath
                            
                            property int relIdx: isToday ? (index - window.activeHourIndex) : index
                            
                            property real targetAngleDeg: isToday ? (65 + (relIdx * 30)) : (index * (360 / Math.max(1, mCount)))
                            
                            property real orbitOffset: isToday ? 0 : (window.globalOrbitAngle * (180 / Math.PI) * -1.5)
                            property real osc: isToday ? (Math.sin(window.globalOrbitAngle * 10 + index) * 5) : 0 
                            
                            // Integrated window.transitionSpin directly into the final angle calculation
                            property real rad: (targetAngleDeg + orbitOffset + osc + window.transitionSpin) * (Math.PI / 180)

                            x: Math.cos(rad) * rx - width/2
                            y: Math.sin(rad) * ry - height/2
                            z: Math.sin(rad) * Math.round(100 * window.sf) 
                            
                            scale: isHighlighted ? 1.4 : (isToday ? (0.95 + 0.20 * Math.sin(rad)) : (0.90 + 0.25 * Math.sin(rad)))
                            opacity: isHighlighted ? 1.0 : (isToday ? (0.7 + 0.3 * ((Math.sin(rad) + 1) / 2)) : (0.65 + 0.35 * ((Math.sin(rad) + 1) / 2)))

                            width: Math.round(56 * window.sf); height: Math.round(95 * window.sf)
                            
                            Rectangle {
                                anchors.fill: parent
                                radius: Math.round(28 * window.sf)
                                color: isHighlighted ? window.textAccent : (hrMa.containsMouse ? window.surface2 : window.surface0)
                                border.color: isHighlighted ? "transparent" : (hrMa.containsMouse ? window.textAccent : window.surface1)
                                border.width: 1
                                
                                Behavior on color { ColorAnimation { duration: 200 } }
                                
                                ColumnLayout {
                                    anchors.centerIn: parent 
                                    spacing: Math.round(4 * window.sf)
                                    
                                    Text { 
                                        Layout.alignment: Qt.AlignHCenter
                                        text: modelData.time
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(12 * window.sf)
                                        color: isHighlighted ? window.base : (hrMa.containsMouse ? window.text : window.overlay1)
                                    }
                                    
                                    Text { 
                                        Layout.alignment: Qt.AlignHCenter
                                        text: modelData.icon || (window.weatherData && window.weatherData.forecast[window.weatherView] ? window.weatherData.forecast[window.weatherView].icon : "")
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(18 * window.sf)
                                        color: isHighlighted ? window.base : (modelData.hex || window.text)
                                        
                                        transform: Translate { y: hrMa.containsMouse ? Math.round(-3 * window.sf) : 0 }
                                        Behavior on transform { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                                    }
                                    
                                    Text { 
                                        Layout.alignment: Qt.AlignHCenter; text: modelData.temp + "°"
                                        font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: Math.round(14 * window.sf)
                                        color: isHighlighted ? window.base : window.text 
                                    }
                                }
                            }
                            MouseArea { id: hrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor }
                        }
                    }
                }

            }

            // =======================================================
            // DAY VIEW — replaces the entire clock hub while a calendar
            // date is selected: a conventional day pane with a vertical
            // hourly graph and appointment blocks (data via events.py
            // from the standard ~/.calendars vdir store).
            // =======================================================
            Rectangle {
                id: dayViewPanel
                visible: window.selectedDayIso !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                // Sits below the weather bar (which stays visible in day mode)
                anchors.topMargin: Math.round(150 * window.sf)
                width: Math.round(520 * window.sf)
                height: Math.round((window.scheduleModuleExists ? 310 : 330) * window.sf)
                z: 5

                color: Qt.alpha(window.surface0, 0.25)
                radius: Math.round(14 * window.sf)
                border.color: Qt.alpha(window.surface1, 0.4)
                border.width: 1
                opacity: introClock

                readonly property real rowH: Math.round(48 * window.sf)
                readonly property real labelW: Math.round(56 * window.sf)
                readonly property bool selectedIsToday: {
                    let n = new Date();
                    let m = n.getMonth() + 1, d = n.getDate();
                    return window.selectedDayIso ===
                        n.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d;
                }

                // Jump the graph to the first appointment (or 07:00) when a day loads.
                function autoScroll() {
                    let target = 7;
                    for (let i = 0; i < window.dayEvents.length; i++) {
                        if (!window.dayEvents[i].allday) { target = Math.max(0, window.dayEvents[i].startHour - 1); break; }
                    }
                    dayFlick.contentY = Math.max(0, Math.min(target * rowH, dayFlick.contentHeight - dayFlick.height));
                }
                Connections {
                    target: window
                    function onDayEventsChanged() { if (window.selectedDayIso !== "") dayViewPanel.autoScroll(); }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Math.round(16 * window.sf)
                    spacing: Math.round(10 * window.sf)

                    // Header: date · count · back-to-weather
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Math.round(10 * window.sf)
                        Text {
                            text: "󰃰"
                            font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(18 * window.sf)
                            color: window.textAccent
                        }
                        Text {
                            Layout.fillWidth: true
                            text: window.selectedDayLabel
                            font.family: "JetBrains Mono"; font.weight: Font.Black
                            font.pixelSize: Math.round(16 * window.sf)
                            color: window.text
                            elide: Text.ElideRight
                        }
                        Text {
                            text: window.dayEventsLoading ? "…"
                                : (window.dayEvents.length === 0 ? "free"
                                : window.dayEvents.length + (window.dayEvents.length === 1 ? " appointment" : " appointments"))
                            font.family: "JetBrains Mono"; font.pixelSize: Math.round(12 * window.sf)
                            color: window.subtext0
                        }
                        Rectangle {
                            Layout.preferredWidth: Math.round(28 * window.sf)
                            Layout.preferredHeight: Math.round(28 * window.sf)
                            radius: width / 2
                            color: dvCloseMa.containsMouse ? window.surface1 : "transparent"
                            Text {
                                anchors.centerIn: parent; text: "󰅖"
                                font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(14 * window.sf)
                                color: dvCloseMa.containsMouse ? window.text : window.overlay1
                            }
                            MouseArea {
                                id: dvCloseMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: window.clearSelectedDay()
                            }
                        }
                    }

                    // All-day chips (pinned above the hour graph)
                    Flow {
                        Layout.fillWidth: true
                        spacing: Math.round(6 * window.sf)
                        visible: {
                            for (let i = 0; i < window.dayEvents.length; i++)
                                if (window.dayEvents[i].allday) return true;
                            return false;
                        }
                        Repeater {
                            model: window.dayEvents
                            Rectangle {
                                visible: modelData.allday
                                width: adLabel.implicitWidth + Math.round(20 * window.sf)
                                height: Math.round(24 * window.sf)
                                radius: height / 2
                                color: Qt.alpha(window.textAccent, 0.20)
                                border.color: Qt.alpha(window.textAccent, 0.5); border.width: 1
                                Text {
                                    id: adLabel; anchors.centerIn: parent
                                    text: modelData.summary
                                    textFormat: Text.PlainText
                                    font.family: "JetBrains Mono"; font.weight: Font.Bold
                                    font.pixelSize: Math.round(11 * window.sf)
                                    color: window.text
                                }
                            }
                        }
                    }

                    // Hourly graph
                    Flickable {
                        id: dayFlick
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentHeight: 24 * dayViewPanel.rowH
                        boundsBehavior: Flickable.StopAtBounds

                        Item {
                            width: dayFlick.width
                            height: dayFlick.contentHeight

                            // Hour rows: label + gridline
                            Repeater {
                                model: 24
                                Item {
                                    y: index * dayViewPanel.rowH
                                    width: parent.width
                                    height: dayViewPanel.rowH
                                    Text {
                                        x: 0; y: Math.round(-7 * window.sf)
                                        width: dayViewPanel.labelW - Math.round(10 * window.sf)
                                        horizontalAlignment: Text.AlignRight
                                        text: (index < 10 ? "0" : "") + index + ":00"
                                        font.family: "JetBrains Mono"; font.pixelSize: Math.round(11 * window.sf)
                                        color: window.overlay0
                                    }
                                    Rectangle {
                                        x: dayViewPanel.labelW; y: 0
                                        width: parent.width - dayViewPanel.labelW
                                        height: 1
                                        color: Qt.alpha(window.surface1, 0.5)
                                    }
                                }
                            }

                            // "Now" line when viewing today
                            Rectangle {
                                visible: dayViewPanel.selectedIsToday
                                x: dayViewPanel.labelW - Math.round(4 * window.sf)
                                y: (window.currentTime.getHours() + window.currentTime.getMinutes() / 60) * dayViewPanel.rowH
                                width: parent.width - x
                                height: Math.max(1, Math.round(2 * window.sf))
                                radius: height / 2
                                color: window.red
                                opacity: 0.85
                                z: 3
                                Rectangle {
                                    x: 0; anchors.verticalCenter: parent.verticalCenter
                                    width: Math.round(8 * window.sf); height: width; radius: width / 2
                                    color: window.red
                                }
                            }

                            // Appointment blocks, positioned by time
                            Repeater {
                                model: window.dayEvents
                                Rectangle {
                                    visible: !modelData.allday
                                    x: dayViewPanel.labelW + Math.round(6 * window.sf)
                                    y: modelData.startHour * dayViewPanel.rowH + 1
                                    width: parent.width - x - Math.round(8 * window.sf)
                                    height: Math.max(Math.round(26 * window.sf),
                                                     (modelData.endHour - modelData.startHour) * dayViewPanel.rowH - 2)
                                    radius: Math.round(8 * window.sf)
                                    color: evMa.containsMouse ? Qt.alpha(window.textAccent, 0.45)
                                                              : Qt.alpha(window.textAccent, 0.30)
                                    border.color: window.textAccent
                                    border.width: 1
                                    z: 2
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Rectangle {   // left time-rail accent
                                        x: 0; y: 0; width: Math.round(4 * window.sf); height: parent.height
                                        radius: width / 2
                                        color: window.textAccent
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Math.round(12 * window.sf)
                                        anchors.rightMargin: Math.round(8 * window.sf)
                                        spacing: Math.round(10 * window.sf)
                                        Text {
                                            text: modelData.start + "\n" + modelData.end
                                            font.family: "JetBrains Mono"; font.weight: Font.Black
                                            font.pixelSize: Math.round(10 * window.sf)
                                            color: window.text
                                            opacity: 0.85
                                            visible: parent.height >= Math.round(34 * window.sf)
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.summary
                                            textFormat: Text.PlainText   // external calendar data
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                                            font.pixelSize: Math.round(12 * window.sf)
                                            color: window.text
                                            elide: Text.ElideRight
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: Math.max(1, Math.floor(parent.height / Math.round(16 * window.sf)))
                                        }
                                    }
                                    MouseArea { id: evMa; anchors.fill: parent; hoverEnabled: true }
                                }
                            }

                            // Empty state
                            Text {
                                visible: !window.dayEventsLoading && window.dayEvents.length === 0
                                x: dayViewPanel.labelW + Math.round(20 * window.sf)
                                y: 8 * dayViewPanel.rowH + Math.round(8 * window.sf)
                                text: "No appointments — enjoy the free day"
                                font.family: "JetBrains Mono"; font.pixelSize: Math.round(12 * window.sf)
                                color: window.overlay1
                            }
                        }
                    }
                }
            }

            // =======================================================
            // LEFT WING: FLOATING GLASS CALENDAR
            // =======================================================
            Rectangle {
                id: calendarRect
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: Math.round(24 * window.sf)
                width: Math.round(320 * window.sf)
                color: Qt.alpha(window.surface0, 0.2) 
                radius: Math.round(14 * window.sf)
                border.color: Qt.alpha(window.surface1, 0.4)
                border.width: 1
                z: 10 

                opacity: introCalendar
                transform: Translate { x: Math.round(-40 * window.sf) * (1.0 - introCalendar) }

                HoverHandler { id: calHover }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Math.round(25 * window.sf)
                    spacing: Math.round(15 * window.sf)

                    RowLayout {
                        Layout.fillWidth: true
                        
                        // "Return to Today" Home Button
                        Rectangle {
                            Layout.preferredWidth: Math.round(32 * window.sf); Layout.preferredHeight: Math.round(32 * window.sf); radius: Math.round(16 * window.sf)
                            color: homeMa.containsMouse ? window.surface1 : "transparent"
                            opacity: window.targetMonthOffset !== 0 ? 1.0 : 0.0
                            visible: opacity > 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                            Text { anchors.centerIn: parent; text: "󰃭"; font.family: "Iosevka Nerd Font"; color: window.text; font.pixelSize: Math.round(16 * window.sf) }
                            MouseArea { 
                                id: homeMa; anchors.fill: parent; hoverEnabled: window.targetMonthOffset !== 0; 
                                onClicked: if (window.targetMonthOffset !== 0) window.setMonthOffset(0) 
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: Math.round(32 * window.sf); Layout.preferredHeight: Math.round(32 * window.sf); radius: Math.round(16 * window.sf)
                            color: prevMa.containsMouse ? window.surface1 : "transparent"
                            Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; color: window.text; font.pixelSize: Math.round(16 * window.sf) }
                            MouseArea { id: prevMa; anchors.fill: parent; hoverEnabled: true; onClicked: window.setMonthOffset(window.targetMonthOffset - 1) }
                        }
                        
                        Text {
                            Layout.fillWidth: true
                            text: window.targetMonthName.toUpperCase()
                            font.family: "JetBrains Mono"
                            font.weight: Font.Black
                            font.pixelSize: Math.round(16 * window.sf)
                            fontSizeMode: Text.Fit
                            minimumPixelSize: Math.round(8 * window.sf)
                            color: window.text
                            horizontalAlignment: Text.AlignHCenter
                            
                            opacity: window.calendarContentOpacity
                            transform: Translate { x: window.calendarContentOffset }
                        }

                        Rectangle {
                            Layout.preferredWidth: Math.round(32 * window.sf); Layout.preferredHeight: Math.round(32 * window.sf); radius: Math.round(16 * window.sf)
                            color: nextMa.containsMouse ? window.surface1 : "transparent"
                            Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; color: window.text; font.pixelSize: Math.round(16 * window.sf) }
                            MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true; onClicked: window.setMonthOffset(window.targetMonthOffset + 1) }
                        }

                        Rectangle {
                            Layout.preferredWidth: Math.round(32 * window.sf); Layout.preferredHeight: Math.round(32 * window.sf); radius: Math.round(16 * window.sf)
                            color: diaryMa.containsMouse ? window.surface1 : "transparent"
                            Text { anchors.centerIn: parent; text: "+"; font.family: "Iosevka Nerd Font"; color: diaryMa.containsMouse ? window.mauve : window.text; font.pixelSize: Math.round(32 * window.sf) }
                            MouseArea { 
                                id: diaryMa; anchors.fill: parent; hoverEnabled: true; 
                                onClicked: Quickshell.execDetached(["bash", window.scriptsDir + "/diary_manager.sh"]) 
                            }
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Repeater {
                            model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                            Text {
                                Layout.fillWidth: true
                                text: modelData
                                font.family: "JetBrains Mono"
                                font.weight: Font.Black
                                font.pixelSize: Math.round(14 * window.sf)
                                color: window.overlay0
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        columns: 7
                        rowSpacing: Math.round(6 * window.sf)
                        columnSpacing: Math.round(6 * window.sf)

                        opacity: window.calendarContentOpacity
                        transform: Translate { x: window.calendarContentOffset }

                        Repeater {
                            model: calendarModel
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                property bool isSelected: isCurrentMonth
                                    && window.selectedDayNum === parseInt(dayNum)
                                    && window.selectedDayMonthOffset === window.monthOffset

                                color: isToday ? window.textAccent
                                     : (isSelected ? Qt.alpha(window.textAccent, 0.30)
                                     : (dayMa.containsMouse ? Qt.alpha(window.surface2, 0.4) : "transparent"))
                                radius: Math.round(10 * window.sf)
                                scale: dayMa.containsMouse ? 1.2 : 1.0
                                border.color: isToday ? window.surface0
                                            : (isSelected ? window.textAccent
                                            : (dayMa.containsMouse ? window.overlay0 : "transparent"))
                                border.width: isToday || isSelected || dayMa.containsMouse ? 1 : 0

                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

                                Text {
                                    anchors.centerIn: parent
                                    text: dayNum
                                    font.family: "JetBrains Mono"
                                    font.weight: isToday ? Font.Black : Font.Bold
                                    font.pixelSize: Math.round(14 * window.sf)
                                    color: isToday ? window.base : (isCurrentMonth ? window.text : window.surface0)
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }

                                MouseArea {
                                    id: dayMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: isCurrentMonth ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: if (isCurrentMonth) window.selectDay(dayNum)
                                }
                            }
                        }
                    }
                }
            }

            // =======================================================
            // TOP WEATHER BAR: [FEELS · WIND]  [◄ DAY ►]  [HUMID · RAIN]
            // One bar sitting ABOVE the hourly-forecast orbit. Left group is
            // feels-like + wind, the centre is the day-of-week pill with the ◄ ►
            // arrows, the right group is humidity + rain.
            // =======================================================
            Item {
                id: weatherBar
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Math.round(16 * window.sf)
                width: Math.round(620 * window.sf)
                height: Math.round(118 * window.sf)
                z: 10

                opacity: introWeather
                transform: Translate { y: Math.round(-30 * window.sf) * (1.0 - introWeather) }

                RowLayout {
                    anchors.fill: parent
                    spacing: Math.round(16 * window.sf)

                    // LEFT — feels-like + wind
                    Repeater { model: [3, 0]; delegate: gaugeDelegate }

                    // CENTRE — day-of-week pill with the ◄ ► arrows
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(64 * window.sf)
                        Layout.alignment: Qt.AlignVCenter

                        RowLayout {
                            anchors.fill: parent
                            spacing: Math.round(16 * window.sf)
                        
                        MouseArea { 
                            id: wPrevMa; Layout.preferredWidth: Math.round(30 * window.sf); Layout.preferredHeight: Math.round(30 * window.sf); hoverEnabled: true
                            onClicked: window.setWeatherView(window.targetWeatherView - 1) 
                            
                            readonly property real pulseOffset: Math.round(-3 * window.sf) * (1 - Math.cos(2 * Math.PI * window.ambientPhase / 2000)) / 2
                            
                            Text { 
                                anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(18 * window.sf)
                                color: parent.containsMouse ? window.textAccent : window.overlay1
                                transform: Translate { x: parent && parent.containsMouse ? Math.round(-5 * window.sf) : wPrevMa.pulseOffset }
                                Behavior on transform { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                            }
                        }
                        
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Math.round(1 * window.sf)

                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: window.weatherData && window.weatherData.forecast[window.weatherView] ? window.weatherData.forecast[window.weatherView].day_full.toUpperCase() : "LOADING..."
                                textFormat: Text.PlainText
                                font.family: "JetBrains Mono"
                                font.weight: Font.Black
                                font.pixelSize: Math.round(16 * window.sf)
                                fontSizeMode: Text.Fit
                                minimumPixelSize: Math.round(8 * window.sf)
                                color: window.text
                            }

                            // Selected day's temp + forecast, small, tucked under the day name
                            // between the arrows (replaces the old big temperature block).
                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: window.weatherData && window.weatherData.forecast[window.weatherView]
                                      ? (Math.round(window.displayedTemp) + "°  ·  " + window.weatherData.forecast[window.weatherView].desc)
                                      : ""
                                textFormat: Text.PlainText
                                font.family: "JetBrains Mono"
                                font.weight: Font.Bold
                                font.pixelSize: Math.round(11 * window.sf)
                                elide: Text.ElideRight
                                color: window.textAccent
                                opacity: window.weatherContentOpacity
                                Behavior on color { ColorAnimation { duration: 1000 } }
                            }
                        }
                        
                        MouseArea { 
                            id: wNextMa; Layout.preferredWidth: Math.round(30 * window.sf); Layout.preferredHeight: Math.round(30 * window.sf); hoverEnabled: true
                            onClicked: window.setWeatherView(window.targetWeatherView + 1)
                            
                            readonly property real pulseOffset: Math.round(3 * window.sf) * (1 - Math.cos(2 * Math.PI * window.ambientPhase / 2000)) / 2
                            
                            Text { 
                                anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(18 * window.sf)
                                color: parent.containsMouse ? window.textAccent : window.overlay1
                                transform: Translate { x: parent && parent.containsMouse ? Math.round(5 * window.sf) : wNextMa.pulseOffset }
                                Behavior on transform { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                            }
                        }
                            }
                    }

                    // RIGHT — humidity + rain
                    Repeater { model: [1, 2]; delegate: gaugeDelegate }

                    // Reusable circular stat gauge, instantiated by both Repeaters above.
                    // `modelData` is the metric id: 0=wind, 1=humid, 2=rain, 3=feels.
                    Component {
                        id: gaugeDelegate
                        Item {
                                id: gaugeWrapper
                                property int kind: modelData
                                Layout.preferredWidth: Math.round(70 * window.sf)
                                Layout.preferredHeight: Math.round(92 * window.sf)
                                
                                scale: gaugeMa.containsMouse ? 1.15 : 1.0
                                Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

                                property var forecast: window.weatherData && window.weatherData.forecast[window.targetWeatherView] ? window.weatherData.forecast[window.targetWeatherView] : null


                                property string gaugeIcon: kind === 0 ? "" : kind === 1 ? "" : kind === 2 ? "" : ""
                                property string gaugeLbl: kind === 0 ? "WIND" : kind === 1 ? "HUMID" : kind === 2 ? "RAIN" : "FEELS"

                                property string gaugeVal: forecast ? (
                                    kind === 0 ? forecast.wind + "m/s" :
                                    kind === 1 ? forecast.humidity + "%" :
                                    kind === 2 ? forecast.pop + "%" :
                                    forecast.feels_like + "°"
                                ) : ""

                                property real gaugeFill: forecast ? (
                                    kind === 0 ? Math.min(1.0, forecast.wind / 25.0) :
                                    kind === 1 ? forecast.humidity / 100.0 :
                                    kind === 2 ? forecast.pop / 100.0 :
                                    Math.max(0.0, Math.min(1.0, (forecast.feels_like + 15) / 55.0))
                                ) : 0.0
                                
                                // FIX: Use ColumnLayout to enforce perfect relative positioning instead of absolute anchors
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: Math.round(6 * window.sf)
                                    
                                    Item {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: Math.round(60 * window.sf)
                                        Layout.preferredHeight: Math.round(60 * window.sf)
                                        
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: width / 2
                                            color: window.textAccent
                                            opacity: gaugeMa.containsMouse ? 0.3 : 0.0
                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }

                                        Canvas {
                                            id: gaugeCanvas
                                            anchors.fill: parent
                                            rotation: -90 
                                            
                                            property real animProgress: gaugeWrapper.gaugeFill

                                            Behavior on animProgress {
                                                NumberAnimation { duration: 1000; easing.type: Easing.OutExpo }
                                            }

                                            // Repaint on 1/400th steps (<0.5px of arc)
                                            // instead of every animation frame.
                                            property int paintStep: Math.round(animProgress * 400)
                                            onPaintStepChanged: requestPaint()
                                            onWidthChanged: requestPaint()
                                            // Gradient strokes with timeAccent — repaint when it
                                            // changes so the ring doesn't keep a stale colour.
                                            property color accent: window.timeAccent
                                            onAccentChanged: requestPaint()
                                            Component.onCompleted: requestPaint()
                                            
                                            onPaint: {
                                                var ctx = getContext("2d");
                                                ctx.clearRect(0, 0, width, height);
                                                var r = width / 2;
                                                
                                                ctx.beginPath();
                                                ctx.arc(r, r, r - Math.round(4 * window.sf), 0, 2 * Math.PI);
                                                ctx.strokeStyle = Qt.alpha(window.text, 0.1);
                                                ctx.lineWidth = Math.round(3 * window.sf);
                                                ctx.stroke();
                                                
                                                if (animProgress > 0) {
                                                    ctx.beginPath();
                                                    ctx.arc(r, r, r - Math.round(4 * window.sf), 0, animProgress * 2 * Math.PI);
                                                    var grad = ctx.createLinearGradient(0, 0, width, height);
                                                    grad.addColorStop(0, window.timeAccent);
                                                    grad.addColorStop(1, window.sapphire);
                                                    ctx.strokeStyle = grad;
                                                    ctx.lineWidth = Math.round(4 * window.sf);
                                                    ctx.lineCap = "round";
                                                    ctx.stroke();
                                                }
                                            }
                                        }
                                        
                                        Text {
                                            anchors.centerIn: parent
                                            text: gaugeWrapper.gaugeVal
                                            font.family: "JetBrains Mono"
                                            font.weight: Font.Black
                                            font.pixelSize: Math.round(12 * window.sf) // Slightly reduced to guarantee fit inside circle
                                            color: window.text
                                        }
                                    }
                                    
                                    RowLayout {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.fillWidth: true
                                        spacing: Math.round(4 * window.sf)
                                        
                                        Text { 
                                            text: gaugeWrapper.gaugeIcon
                                            font.family: "Iosevka Nerd Font"
                                            font.pixelSize: Math.round(12 * window.sf)
                                            color: gaugeMa.containsMouse ? window.textAccent : window.overlay0
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                        }
                                        Text { 
                                            text: gaugeWrapper.gaugeLbl
                                            Layout.fillWidth: true
                                            font.family: "JetBrains Mono"
                                            font.weight: Font.Bold
                                            font.pixelSize: Math.round(11 * window.sf)
                                            fontSizeMode: Text.Fit
                                            minimumPixelSize: Math.round(6 * window.sf)
                                            color: window.overlay0 
                                        }
                                    }
                                }
                                
                                MouseArea { id: gaugeMa; anchors.fill: parent; hoverEnabled: true }
                            }
                        }
                    }
                }

            // =======================================================
            // BOTTOM SECTION: FRAMELESS FLUID DATA STREAM (SCHEDULE)
            // =======================================================
            Item {
                id: bottomSection
                
                // CONDITIONAL RENDERING BINDING
                visible: window.scheduleModuleExists
                
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.round(240 * window.sf)
                z: 20 

                opacity: introSchedule
                transform: Translate { y: Math.round(50 * window.sf) * (1.0 - introSchedule) }

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.alpha(window.crust, 0.6) }
                    }
                }

                Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: Qt.alpha(window.surface1, 0.5) }

                // OPTIMIZATION: Separated the massive continuous Canvas path-drawing loop into three pre-rendered hardware-accelerated static layers.
                Item {
                    anchors.fill: parent
                    z: -1
                    opacity: 0.15
                    clip: true

                    // Wave 1 - Mauve
                    Canvas {
                        id: wave1
                        property real wLen: Math.round(100 * window.sf) * 2 * Math.PI
                        width: parent.width + wLen
                        height: parent.height
                        
                        NumberAnimation on x { from: 0; to: -wave1.wLen; duration: 4000; loops: Animation.Infinite; running: window.scheduleModuleExists && window.visible }
                        
                        onWidthChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            var cy = height / 2;
                            ctx.beginPath();
                            ctx.moveTo(0, cy);
                            for(var i = 0; i <= width + Math.round(20 * window.sf); i += Math.round(10 * window.sf)) {
                                ctx.lineTo(i, cy + Math.sin(i/Math.round(100 * window.sf)) * Math.round(30 * window.sf));
                            }
                            ctx.strokeStyle = window.mauve;
                            ctx.lineWidth = Math.round(2 * window.sf);
                            ctx.stroke();
                        }
                    }

                    // Wave 2 - Sapphire
                    Canvas {
                        id: wave2
                        property real wLen: Math.round(120 * window.sf) * 2 * Math.PI
                        width: parent.width + wLen
                        height: parent.height
                        
                        NumberAnimation on x { from: -wave2.wLen; to: 0; duration: 5500; loops: Animation.Infinite; running: window.scheduleModuleExists && window.visible }
                        
                        onWidthChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            var cy = height / 2;
                            ctx.beginPath();
                            ctx.moveTo(0, cy);
                            for(var i = 0; i <= width + Math.round(20 * window.sf); i += Math.round(10 * window.sf)) {
                                ctx.lineTo(i, cy + Math.sin(i/Math.round(120 * window.sf)) * Math.round(40 * window.sf));
                            }
                            ctx.strokeStyle = window.sapphire;
                            ctx.lineWidth = Math.round(2 * window.sf);
                            ctx.stroke();
                        }
                    }

                    // Wave 3 - Peach
                    Canvas {
                        id: wave3
                        property real wLen: Math.round(80 * window.sf) * 2 * Math.PI
                        width: parent.width + wLen
                        height: parent.height
                        
                        NumberAnimation on x { from: 0; to: -wave3.wLen; duration: 7000; loops: Animation.Infinite; running: window.scheduleModuleExists && window.visible }
                        
                        onWidthChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            var cy = height / 2;
                            ctx.beginPath();
                            ctx.moveTo(0, cy);
                            for(var i = 0; i <= width + Math.round(20 * window.sf); i += Math.round(10 * window.sf)) {
                                ctx.lineTo(i, cy + Math.sin(i/Math.round(80 * window.sf)) * Math.round(20 * window.sf));
                            }
                            ctx.strokeStyle = window.peach;
                            ctx.lineWidth = Math.round(2 * window.sf);
                            ctx.stroke();
                        }
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Math.round(25 * window.sf)
                    spacing: Math.round(15 * window.sf)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Math.round(15 * window.sf)
                        
                        Rectangle {
                            Layout.preferredWidth: Math.round(40 * window.sf); Layout.preferredHeight: Math.round(40 * window.sf); radius: Math.round(20 * window.sf); color: window.surface0
                            Text { anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(18 * window.sf); color: window.textAccent }
                        }
                        
                        Text { 
                            Layout.fillWidth: true // FIX: Ensures text shrinks/elides instead of expanding layout infinitely
                            text: window.scheduleData ? window.scheduleData.header : "Loading Schedule..."
                            textFormat: Text.PlainText
                            font.family: "JetBrains Mono"
                            font.weight: Font.Bold
                            font.pixelSize: Math.round(16 * window.sf)
                            color: window.overlay0
                            elide: Text.ElideRight
                        }
                        
                        Item { Layout.fillWidth: true }
                        
                        Rectangle {
                            Layout.preferredWidth: Math.round(120 * window.sf); Layout.preferredHeight: Math.round(36 * window.sf); radius: Math.round(10 * window.sf)
                            color: schLinkMa.containsMouse ? window.mauve : Qt.alpha(window.surface1, 0.5)
                            border.color: window.mauve; border.width: 1
                            Behavior on color { ColorAnimation { duration: 150 } }
                            
                            RowLayout {
                                anchors.centerIn: parent
                                spacing: Math.round(6 * window.sf)
                                Text { text: "Open Web"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(14 * window.sf); color: schLinkMa.containsMouse ? window.base : window.text }
                                Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(14 * window.sf); color: schLinkMa.containsMouse ? window.base : window.text }
                            }
                            
                            MouseArea {
                                id: schLinkMa; anchors.fill: parent; hoverEnabled: true
                                // Only hand xdg-open a web URL: accept http(s) as-is,
                                // upgrade a bare host/path to https, refuse anything
                                // else (file:, custom schemes, shell-ish strings).
                                onClicked: {
                                    var u = (window.scheduleData && window.scheduleData.link) ? String(window.scheduleData.link).trim() : "";
                                    if (!u) return;
                                    if (!/^https?:\/\//i.test(u)) {
                                        if (/^[\w.-]+(\/\S*)?$/.test(u)) u = "https://" + u;
                                        else return;
                                    }
                                    Quickshell.execDetached(["xdg-open", u]);
                                }
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        Text {
                            text: "Data stream offline. No scheduled events."
                            font.family: "JetBrains Mono"
                            font.italic: true
                            font.pixelSize: Math.round(14 * window.sf)
                            color: window.overlay0
                            visible: window.scheduleData && window.scheduleData.lessons.length === 0
                            anchors.centerIn: parent
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: Math.round(2 * window.sf)
                            color: Qt.alpha(window.surface1, 0.4)
                            visible: window.scheduleData && window.scheduleData.lessons.length > 0
                        }

                        ScrollView {
                            id: schedScroll
                            anchors.fill: parent
                            clip: true
                            ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                            ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                            visible: window.scheduleData && window.scheduleData.lessons.length > 0
                            contentWidth: scheduleRow.width
                            contentHeight: parent.height

                            Row {
                                id: scheduleRow
                                height: parent.height
                                spacing: 0
                                
                                // Divide the actual rendered width of the scroll area by the 430 minutes in a standard school day 
                                // to get the dynamic Pixels Per Minute ratio that stretches perfectly across the entire space.
                                property real ppm: schedScroll.width / 430.0

                                Repeater {
                                    model: window.scheduleData ? window.scheduleData.lessons : []

                                    delegate: Item {
                                        property bool isClass: modelData.type === "class"
                                        
                                        // Calculate the exact duration in minutes directly from the start and end epochs 
                                        property real durationMinutes: ((modelData.end || 0) - (modelData.start || 0)) / 60.0
                                        
                                        // Multiply duration by PPM and round to the nearest whole pixel to avoid sub-pixel gaps entirely
                                        width: Math.max(1, Math.round(durationMinutes * scheduleRow.ppm))
                                        height: parent.height
                                        
                                        Item {
                                            id: classNode
                                            anchors.fill: parent
                                            anchors.topMargin: Math.round(10 * window.sf)
                                            anchors.bottomMargin: Math.round(10 * window.sf)
                                            visible: parent.isClass
                                            
                                            property bool isActive: parent.isClass && window.currentEpoch >= (modelData.start || 0) && window.currentEpoch <= (modelData.end || 0)
                                            property bool isPast: parent.isClass && window.currentEpoch > (modelData.end || 0)
                                            
                                            Canvas {
                                                anchors.fill: parent
                                                visible: classMa.containsMouse || classNode.isActive
                                                opacity: classMa.containsMouse ? 0.2 : 0.08
                                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                                
                                                property real wavePhase: 0
                                                NumberAnimation on wavePhase {
                                                    from: 0; to: Math.PI * 2; duration: 2000; loops: Animation.Infinite; running: parent.visible
                                                }
                                                onWavePhaseChanged: requestPaint()
                                                onPaint: {
                                                    var ctx = getContext("2d");
                                                    ctx.clearRect(0, 0, width, height);
                                                    ctx.beginPath();
                                                    ctx.moveTo(0, height);
                                                    for(var x = 0; x <= width; x += Math.round(10 * window.sf)) {
                                                        ctx.lineTo(x, height/2 + Math.sin(x/Math.round(25 * window.sf) + wavePhase) * Math.round(20 * window.sf));
                                                    }
                                                    ctx.lineTo(width, height);
                                                    ctx.lineTo(0, height);
                                                    var grad = ctx.createLinearGradient(0, 0, width, 0);
                                                    grad.addColorStop(0, window.mauve);
                                                    grad.addColorStop(1, "transparent");
                                                    ctx.fillStyle = grad;
                                                    ctx.fill();
                                                }
                                            }

                                            Rectangle {
                                                id: accentLine
                                                width: classNode.isActive || classMa.containsMouse ? Math.round(4 * window.sf) : Math.round(2 * window.sf)
                                                anchors.left: parent.left
                                                anchors.top: parent.top
                                                anchors.bottom: parent.bottom
                                                radius: Math.round(2 * window.sf)
                                                color: classNode.isActive ? window.mauve : (classNode.isPast ? window.surface1 : window.surface2)
                                                Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                                                Behavior on color { ColorAnimation { duration: 200 } }
                                            }

                                            ColumnLayout {
                                                anchors.left: accentLine.right
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: classMa.containsMouse ? Math.round(25 * window.sf) : Math.round(15 * window.sf)
                                                Behavior on anchors.leftMargin { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
                                                spacing: Math.round(6 * window.sf)

                                                Text {
                                                    text: modelData.subject || ""
                                                    textFormat: Text.PlainText
                                                    font.family: "JetBrains Mono"
                                                    font.weight: Font.Black
                                                    font.pixelSize: Math.round(16 * window.sf)
                                                    color: classNode.isActive ? window.mauve : (classNode.isPast ? window.overlay0 : window.text)
                                                    elide: Text.ElideRight
                                                    Layout.fillWidth: true
                                                }

                                                RowLayout {
                                                    visible: !modelData.is_compact
                                                    spacing: Math.round(8 * window.sf)
                                                    Text { text: "󰅐"; font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(14 * window.sf); color: classNode.isActive ? window.mauve : window.overlay1 }
                                                    Text { text: modelData.time || ""; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(14 * window.sf); color: classNode.isActive ? window.text : window.overlay1 }
                                                }

                                                RowLayout {
                                                    visible: !modelData.is_compact && (modelData.room || "") !== ""
                                                    spacing: Math.round(8 * window.sf)
                                                    Text { text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: Math.round(14 * window.sf); color: classNode.isPast ? window.surface2 : window.peach }
                                                    Text { text: modelData.room || ""; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(14 * window.sf); color: window.subtext1; elide: Text.ElideRight; Layout.fillWidth: true }
                                                }
                                            }

                                            MouseArea { id: classMa; anchors.fill: parent; hoverEnabled: parent.visible }
                                        }

                                        Item {
                                            anchors.fill: parent
                                            visible: !parent.isClass
                                            
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                height: gapMa.containsMouse ? Math.round(4 * window.sf) : Math.round(2 * window.sf)
                                                color: gapMa.containsMouse ? window.mauve : "transparent"
                                                Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
                                                Behavior on color { ColorAnimation { duration: 150 } }
                                            }

                                            Rectangle {
                                                anchors.centerIn: parent
                                                width: breakText.width + Math.round(16 * window.sf)
                                                height: Math.round(24 * window.sf)
                                                radius: Math.round(6 * window.sf)
                                                color: window.mantle
                                                border.color: window.surface2
                                                border.width: 1
                                                opacity: gapMa.containsMouse ? 1.0 : 0.0
                                                scale: gapMa.containsMouse ? 1.0 : 0.8
                                                Behavior on opacity { NumberAnimation { duration: 150 } }
                                                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }

                                                Text {
                                                    id: breakText
                                                    anchors.centerIn: parent
                                                    text: modelData.desc || ""
                                                    font.family: "JetBrains Mono"
                                                    font.weight: Font.Bold
                                                    font.pixelSize: Math.round(14 * window.sf)
                                                    color: window.mauve
                                                }
                                            }

                                            MouseArea { id: gapMa; anchors.fill: parent; hoverEnabled: parent.visible }
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

    // =======================================================
    // NEWS READER — opens IN PLACE of the calendar (the master window grows to
    // targetMasterHeight while newsReaderOpen). Left = headline list, right =
    // selected article; "← Back" returns to the calendar.
    // =======================================================
    Item {
        id: newsReader
        anchors.fill: parent
        z: 100
        visible: opacity > 0.01
        opacity: window.newsReaderOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // Swallow clicks so nothing behind (or the backdrop) reacts.
        MouseArea { anchors.fill: parent }

        Rectangle {
            anchors.fill: parent
            radius: Math.round(20 * window.sf)
            color: window.base
            border.color: window.surface0; border.width: 1
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Math.round(24 * window.sf)
                spacing: Math.round(16 * window.sf)

                // ── Header ──
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Math.round(12 * window.sf)

                    Rectangle {
                        Layout.preferredWidth: Math.round(100 * window.sf); Layout.preferredHeight: Math.round(34 * window.sf)
                        radius: Math.round(10 * window.sf)
                        color: backMa.containsMouse ? window.surface1 : Qt.alpha(window.surface0, 0.6)
                        border.color: window.surface1; border.width: 1
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text { anchors.centerIn: parent; text: "←  Back"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(12 * window.sf); color: window.text }
                        MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.newsReaderOpen = false }
                    }
                    Text { text: "News"; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: Math.round(18 * window.sf); color: window.text }
                    Item { Layout.fillWidth: true }
                    Text { text: window.newsItems.length + " stories"; font.family: "JetBrains Mono"; font.pixelSize: Math.round(11 * window.sf); color: window.overlay1 }
                }

                // ── Body: headline list (left) + article (right) ──
                RowLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    spacing: Math.round(18 * window.sf)

                    Rectangle {
                        Layout.preferredWidth: Math.round(400 * window.sf)
                        Layout.fillHeight: true
                        radius: Math.round(14 * window.sf)
                        color: Qt.alpha(window.surface0, 0.25)
                        border.color: Qt.alpha(window.surface1, 0.4); border.width: 1
                        clip: true

                        ListView {
                            id: newsList
                            anchors.fill: parent; anchors.margins: Math.round(6 * window.sf)
                            clip: true; spacing: Math.round(4 * window.sf)
                            model: window.newsItems
                            currentIndex: window.newsReaderIndex

                            delegate: Rectangle {
                                width: ListView.view.width
                                height: Math.round(64 * window.sf)
                                radius: Math.round(10 * window.sf)
                                color: index === window.newsReaderIndex ? Qt.alpha(window.textAccent, 0.18)
                                     : (rowMa.containsMouse ? Qt.alpha(window.surface1, 0.4) : "transparent")
                                Behavior on color { ColorAnimation { duration: 120 } }

                                RowLayout {
                                    anchors.fill: parent; anchors.margins: Math.round(6 * window.sf); spacing: Math.round(8 * window.sf)
                                    Rectangle {
                                        Layout.preferredWidth: Math.round(52 * window.sf); Layout.preferredHeight: Math.round(52 * window.sf)
                                        radius: Math.round(8 * window.sf); clip: true; color: Qt.alpha(window.surface1, 0.5)
                                        visible: modelData.image
                                        Image { anchors.fill: parent; source: modelData.image || ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: Math.round(104 * window.sf); sourceSize.height: Math.round(104 * window.sf) }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true; spacing: Math.round(2 * window.sf)
                                        Text { Layout.fillWidth: true; text: (modelData.source || "") + "  ·  " + window.newsAgo(modelData.ts); textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.pixelSize: Math.round(8 * window.sf); color: window.textAccent; elide: Text.ElideRight }
                                        Text { Layout.fillWidth: true; text: modelData.title || ""; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(11 * window.sf); color: window.text; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                    }
                                }
                                MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: window.newsReaderIndex = index }
                            }
                        }
                    }

                    Flickable {
                        id: artFlick
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentWidth: width; contentHeight: artCol.implicitHeight; clip: true

                        ColumnLayout {
                            id: artCol
                            width: artFlick.width
                            spacing: Math.round(12 * window.sf)

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.round(240 * window.sf)
                                radius: Math.round(14 * window.sf); clip: true
                                color: Qt.alpha(window.surface0, 0.4)
                                visible: window.newsCurrent && window.newsCurrent.image
                                Image { anchors.fill: parent; source: (window.newsCurrent && window.newsCurrent.image) || ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: Math.round(900 * window.sf); sourceSize.height: Math.round(500 * window.sf) }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: window.newsCurrent ? ((window.newsCurrent.source || "") + "  ·  " + window.newsAgo(window.newsCurrent.ts)) : ""
                                textFormat: Text.PlainText
                                font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(11 * window.sf); color: window.textAccent
                            }
                            Text {
                                Layout.fillWidth: true
                                text: window.newsCurrent ? (window.newsCurrent.title || "") : ""
                                textFormat: Text.PlainText
                                font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: Math.round(22 * window.sf); color: window.text; wrapMode: Text.Wrap
                            }
                            Text {
                                Layout.fillWidth: true
                                text: window.newsCurrent ? (window.newsCurrent.body || window.newsCurrent.summary || "") : ""
                                textFormat: Text.PlainText
                                font.family: "JetBrains Mono"; font.pixelSize: Math.round(13 * window.sf); color: window.subtext0; wrapMode: Text.Wrap; lineHeight: 1.3
                            }
                            Rectangle {
                                Layout.preferredWidth: Math.round(190 * window.sf); Layout.preferredHeight: Math.round(38 * window.sf)
                                Layout.topMargin: Math.round(6 * window.sf)
                                radius: Math.round(10 * window.sf)
                                color: openMa.containsMouse ? window.mauve : Qt.alpha(window.mauve, 0.85)
                                visible: window.newsCurrent && window.newsCurrent.url
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Text { anchors.centerIn: parent; text: "Open in browser  ↗"; font.family: "JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: Math.round(12 * window.sf); color: window.base }
                                MouseArea { id: openMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { var u = window.newsCurrent ? window.newsCurrent.url : ""; if (u && /^https?:\/\//i.test(u)) Quickshell.execDetached(["xdg-open", u]); } }
                            }
                        }
                    }
                }
            }
        }
    }
}
