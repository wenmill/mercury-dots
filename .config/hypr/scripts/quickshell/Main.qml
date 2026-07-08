import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "WindowRegistry.js" as Registry

import "notifications" as Notifs

PanelWindow {
    id: masterWindow
    color: "transparent"

    Caching { id: paths }

    // ── Hermes setup ──────────────────────────────────────────────────────────
    // No state-dir bootstrap needed here. Only the heavy agent warmup remains,
    // deferred off the critical launch path below.

    // Deferred, one-shot agent warmup (`hermes --version` loads venv/model paths, ~0.66s).
    // Running it at boot just added subprocess contention while the bar was trying to paint;
    // 4s later it's off the critical path but still warm well before any realistic prompt.
    Timer {
        interval: 4000; running: true; repeat: false
        onTriggered: hermesWarmup.running = true
    }
    Process {
        id: hermesWarmup
        command: ["bash", "-c",
            "export PATH=\"$HOME/.local/bin:$HOME/bin:$HOME/.hermes/venv/bin:$HOME/.cargo/bin:$PATH\"; " +
            "command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1 || true"]
    }

    // Re-ensure the state dir exists in case a cache wipe removed it. This was firing every
    // 60s — a pointless bash spawn every minute since the dir never disappears in practice.
    // 10 min keeps the safety net at 1/10th the churn.
    Timer {
        interval: 600000; running: true; repeat: true
        onTriggered: hermesKeepAlive.running = true
    }
    Process {
        id: hermesKeepAlive
        command: ["bash", "-c", "mkdir -p \"$HOME/.cache/qs_ai_state\""]
    }

    IpcHandler {
        target: "main"

        function forceReload(): void {
            Quickshell.reload(true)
        }

        function handleCommand(cmd: string, targetWidget: string, arg: string): void {
            cmd = cmd || "";
            targetWidget = targetWidget || "";
            arg = arg || "";

            let isClosing = (masterWindow.currentActive !== "hidden" && !masterWindow.isVisible);
            let effectivelyActive = isClosing ? "hidden" : masterWindow.currentActive;

            if (cmd === "close") {
                switchWidget("hidden", "");
            } else if (cmd === "toggle" || cmd === "open") {
                delayedClear.stop();

                if (targetWidget === effectivelyActive) {
                    let currentItem = widgetStack.currentItem;

                    if (arg !== "" && currentItem && currentItem.activeMode !== undefined && currentItem.activeMode !== arg) {
                        currentItem.activeMode = arg;
                    } else if (cmd === "toggle") {
                        switchWidget("hidden", "");
                    }
                } else if (getLayout(targetWidget)) {
                    switchWidget(targetWidget, arg);
                }
            } else if (getLayout(cmd)) {
                let legacyArg = targetWidget;
                delayedClear.stop();

                if (cmd === effectivelyActive) {
                    let currentItem = widgetStack.currentItem;
                    if (legacyArg !== "" && currentItem && currentItem.activeMode !== undefined && currentItem.activeMode !== legacyArg) {
                        currentItem.activeMode = legacyArg;
                    } else {
                        switchWidget("hidden", "");
                    }
                } else {
                    switchWidget(cmd, legacyArg);
                }
            }
        }
    }

    WlrLayershell.namespace: "qs-master"
    WlrLayershell.layer: WlrLayer.Overlay

    exclusionMode: ExclusionMode.Ignore
    focusable: true

    implicitWidth: masterWindow.screen.width
    implicitHeight: masterWindow.screen.height

    visible: isVisible

    // In mpv player mode the input region is just the player box, so clicks
    // outside it pass through to other windows (you can switch focus while the
    // video stays up). Otherwise: the whole window minus the top-bar hole.
    mask: Region {
        item: masterWindow.movableNow ? boundingBox : topBarHole
        intersection: masterWindow.movableNow ? Intersection.Intersect : Intersection.Xor
    }

    Item {
        id: topBarHole
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 48

        anchors.leftMargin: (masterWindow.currentActive !== "hidden" && masterWindow.animX < 10 && masterWindow.animY < height) ? masterWindow.animW : 0
        anchors.rightMargin: (masterWindow.currentActive !== "hidden" && (masterWindow.animX + masterWindow.animW) > (parent.width - 10) && masterWindow.animY < height) ? masterWindow.animW : 0

        Behavior on anchors.leftMargin {
            enabled: masterWindow.currentActive !== "hidden"
            NumberAnimation { duration: masterWindow.morphDuration; easing.type: Easing.OutCubic }
        }
        Behavior on anchors.rightMargin {
            enabled: masterWindow.currentActive !== "hidden"
            NumberAnimation { duration: masterWindow.morphDuration; easing.type: Easing.OutCubic }
        }
    }

    MouseArea {
        anchors.fill: parent
        // In mpv player mode the popup stays up — clicking off does nothing;
        // only the hotkey closes it.
        enabled: masterWindow.isVisible && !masterWindow.movableNow
        onClicked: switchWidget("hidden", "")
    }

    // =========================================================
    // --- DAEMON: PRELOADING SYSTEM
    // =========================================================
    Item {
        id: preloaderContainer
        visible: false
    }

    property var widgetCache: ({})

    function preloadWidget(name) {
        if (widgetCache[name]) return;
        let t = getLayout(name);
        if (!t || !t.comp) return;
        // t.comp is a URL string (StackView.replace accepts it directly), but to
        // instantiate ahead of time we need a Component first — calling createObject
        // on the bare string silently throws and the cache never populates.
        let comp = Qt.createComponent(Qt.resolvedUrl(t.comp));
        if (comp.status === Component.Error) {
            console.warn("preloadWidget(" + name + "):", comp.errorString());
            return;
        }
        // Only seed visibility here — notifModel/liveNotifs/layout are (re)applied per
        // open by executeSwitch's cached branch, guarded by `!== undefined`, so passing
        // them now just warns on widgets (e.g. settings) that don't declare them.
        let obj = comp.createObject(preloaderContainer, { "visible": false });
        if (obj) widgetCache[name] = obj;
    }

    // Preloads trimmed: settings/search/help are rarely opened and were sitting
    // resident from boot. They now lazy-build on first open like every other
    // widget (executeSwitch's cache-miss path), reclaiming startup RAM at the
    // cost of a small one-time first-open delay. preloadWidget() is kept for
    // any widget that genuinely warrants warm-start in the future.

    // =========================================================

    property string currentActive: "hidden"

    onCurrentActiveChanged: {
        Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "qs-widget", currentActive, paths.runDir + "/current_widget"]);
    }

    property bool isVisible: false
    property string activeArg: ""
    property bool disableMorph: false

    property int morphDuration: 230
    property int morphDurationSwitch: 210
    property int exitDuration: 160

    property real animW: 1
    property real animH: 1
    property real animX: 0
    property real animY: 0

    property real targetW: 1
    property real targetH: 1

    property real globalUiScale: ScaleStore.uiScale

    // ── Movable / resizable window (only while the active widget asks for it,
    //    e.g. the movies widget in mpv player mode) ──────────────────────────
    readonly property bool movableNow:
        widgetStack.currentItem ? (widgetStack.currentItem.windowMovable === true) : false
    readonly property int minWinW: 360
    readonly property int minWinH: 240

    onMovableNowChanged: {
        // Leaving the movable state: snap back to the computed layout geometry.
        if (!movableNow) {
            masterWindow.disableMorph = false;
            handleNativeScreenChange();
        }
    }

    // Resize the shell window to the playing movie's aspect ratio (called when the
    // active widget reports a new videoAspect), keeping it centred and on-screen.
    function applyVideoAspect() {
        if (!movableNow) return;
        let item = widgetStack.currentItem;
        if (!item || item.videoAspect === undefined) return;
        // Fullscreen takes precedence — don't shrink the window back to the
        // content's aspect ratio while the user has asked for fullscreen.
        if (item.playerFullscreen === true) return;
        let a = item.videoAspect;
        if (!a || a <= 0) return;

        let maxW = masterWindow.width  - 80;
        let maxH = masterWindow.height - 80;
        // Start from the current width, derive height from the movie ratio, then
        // fit within the screen.
        let w = masterWindow.animW;
        let h = w / a;
        if (h > maxH) { h = maxH; w = h * a; }
        if (w > maxW) { w = maxW; h = w / a; }
        w = Math.max(minWinW, w);
        h = Math.max(minWinH, h);

        // Preserve the current centre, then clamp inside the screen.
        let cx = masterWindow.animX + masterWindow.animW / 2;
        let cy = masterWindow.animY + masterWindow.animH / 2;
        let nx = Math.round(cx - w / 2);
        let ny = Math.round(cy - h / 2);
        nx = Math.max(0, Math.min(nx, masterWindow.width  - w));
        ny = Math.max(0, Math.min(ny, masterWindow.height - h));

        masterWindow.disableMorph = false;   // animate the snap-to-ratio
        masterWindow.animX = nx; masterWindow.animY = ny;
        masterWindow.animW = w; masterWindow.targetW = w;
        masterWindow.animH = h; masterWindow.targetH = h;
    }

    // Fill the screen (player fullscreen) or restore the aspect-fit size.
    function applyPlayerFullscreen() {
        if (!movableNow) return;
        let item = widgetStack.currentItem;
        if (!item || item.playerFullscreen === undefined) return;
        masterWindow.disableMorph = false;
        if (item.playerFullscreen) {
            masterWindow.animX = 0; masterWindow.animY = 0;
            masterWindow.animW = masterWindow.width;  masterWindow.targetW = masterWindow.width;
            masterWindow.animH = masterWindow.height; masterWindow.targetH = masterWindow.height;
        } else {
            applyVideoAspect();
        }
    }

    Connections {
        target: widgetStack.currentItem
        ignoreUnknownSignals: true
        function onVideoAspectChanged() { masterWindow.applyVideoAspect(); }
        function onPlayerFullscreenChanged() { masterWindow.applyPlayerFullscreen(); }
    }

    // =========================================================
    // --- DAEMON: NOTIFICATION HANDLING
    // =========================================================
    ListModel { id: globalNotificationHistory }
    ListModel { id: activePopupsModel }

    property var liveNotifs: ({})
    property int _popupCounter: 0

    // --- NEW: Startup Grace Period Flag & Timer ---
    property bool isStartup: true
    Timer {
        interval: 500
        running: true
        onTriggered: masterWindow.isStartup = false
    }

    function removePopup(uid) {
        for (let i = 0; i < activePopupsModel.count; i++) {
            if (activePopupsModel.get(i).uid === uid) {
                activePopupsModel.remove(i);
                break;
            }
        }
    } 

    NotificationServer {
        id: globalNotificationServer
        bodySupported: true
        actionsSupported: true
        imageSupported: true

        onNotification: (n) => {
            n.tracked = true;

            let extractedActions = [];
            if (n.actions) {
                for (let i = 0; i < n.actions.length; i++) {
                    extractedActions.push({
                        "id": n.actions[i].identifier || "",
                        "text": n.actions[i].text || n.actions[i].name || "Action"
                    });
                }
            }

            masterWindow._popupCounter++;
            let currentUid = masterWindow._popupCounter;

            // Always store the live object so the history center can interact with it
            masterWindow.liveNotifs[currentUid] = n;

            let notifData = {
                "appName":     n.appName  !== "" ? n.appName  : "System",
                "summary":     n.summary  !== "" ? n.summary  : "No Title",
                "body":        n.body     !== "" ? n.body     : "",
                "iconPath":    n.appIcon  !== "" ? n.appIcon  : "",
                "actionsJson": JSON.stringify(extractedActions),
                "uid":         currentUid,
                "notif":       n
            };

            // Always silently add to the history list
            globalNotificationHistory.insert(0, notifData);

            // Cap history at 200 so neither the model nor liveNotifs grows unbounded across a
            // long uptime. New items are inserted at the front, so the oldest sit at the end.
            while (globalNotificationHistory.count > 200) {
                globalNotificationHistory.remove(globalNotificationHistory.count - 1);
            }
            // Keep liveNotifs bounded to exactly what's still in history — reclaiming both the
            // >200 trim above AND entries the history center's per-item delete leaves stranded
            // (it shrinks the model but never touched this map). Only reassign when something
            // actually dropped, so the common path adds no binding churn.
            let alive = {};
            for (let i = 0; i < globalNotificationHistory.count; i++) {
                let auid = globalNotificationHistory.get(i).uid;
                if (auid !== undefined && masterWindow.liveNotifs[auid] !== undefined)
                    alive[auid] = masterWindow.liveNotifs[auid];
            }
            if (Object.keys(alive).length !== Object.keys(masterWindow.liveNotifs).length)
                masterWindow.liveNotifs = alive;

            // --- CHANGED: Only trigger the visual popup if we are past the startup phase ---
            if (!masterWindow.isStartup) {
                activePopupsModel.append(notifData);
                osdPopups.storeNotif(currentUid, n);
            }
        }
    }

    property var notifModel: globalNotificationHistory

    Notifs.NotificationPopups {
        id: osdPopups
        popupModel: activePopupsModel
        uiScale: masterWindow.globalUiScale
        onRemoveRequested: (uid) => masterWindow.removePopup(uid)
    }
    onGlobalUiScaleChanged: { handleNativeScreenChange(); }

    // globalUiScale binds to the ScaleStore singleton (one settings.json
    // FileView per engine, shared with every Scaler instance).

    // =========================================================
    // --- LAYOUT CACHE
    // =========================================================
    property var    _layoutCache:    ({})
    property string _layoutCacheKey: ""

    function getLayout(name) {
        let key = name + "|" + masterWindow.width + "|" + masterWindow.height + "|" + masterWindow.globalUiScale;
        if (_layoutCacheKey === key) return _layoutCache[key];
        let result = Registry.getLayout(name, 0, 0, masterWindow.width, masterWindow.height, masterWindow.globalUiScale);
        _layoutCache = {};
        _layoutCache[key] = result;
        _layoutCacheKey = key;
        return result;
    }

    Connections {
        target: masterWindow
        function onWidthChanged()  { _layoutCacheKey = ""; handleNativeScreenChange(); }
        function onHeightChanged() { _layoutCacheKey = ""; handleNativeScreenChange(); }
    }

    function handleNativeScreenChange() {
        if (masterWindow.currentActive === "hidden") return;

        let t = getLayout(masterWindow.currentActive);
        if (!t) return;

        let currentItem = widgetStack.currentItem;
        let finalW = (currentItem && currentItem.targetMasterWidth  !== undefined) ? currentItem.targetMasterWidth  : t.w;
        let finalH = (currentItem && currentItem.targetMasterHeight !== undefined) ? currentItem.targetMasterHeight : t.h;
        let finalX = t.rx;
        if (currentItem && currentItem.targetMasterWidth !== undefined && finalW !== t.w) {
            finalX = Math.floor((masterWindow.width / 2) - (finalW / 2));
        }

        masterWindow.animX = finalX;
        masterWindow.animY = t.ry;
        masterWindow.animW = finalW;
        masterWindow.animH = finalH;
        masterWindow.targetW = finalW;
        masterWindow.targetH = finalH;
    }

    onIsVisibleChanged: {
        if (isVisible) widgetStack.forceActiveFocus();
    }

    // =========================================================
    // --- ANIMATED BOUNDING BOX
    // =========================================================
    Item {
        id: boundingBox
        x: masterWindow.animX
        y: masterWindow.animY
        width:  masterWindow.animW
        height: masterWindow.animH
        clip: true

        Behavior on x {
            enabled: !masterWindow.disableMorph
            NumberAnimation { duration: masterWindow.morphDuration; easing.type: Easing.OutCubic }
        }
        Behavior on y {
            enabled: !masterWindow.disableMorph
            NumberAnimation { duration: masterWindow.morphDuration; easing.type: Easing.OutCubic }
        }
        Behavior on width {
            enabled: !masterWindow.disableMorph
            NumberAnimation { duration: masterWindow.morphDuration; easing.type: Easing.OutCubic }
        }
        Behavior on height {
            enabled: !masterWindow.disableMorph
            NumberAnimation { duration: masterWindow.morphDuration; easing.type: Easing.OutCubic }
        }

        opacity: masterWindow.isVisible ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation {
                duration: 160
                easing.type: masterWindow.isVisible ? Easing.OutCubic : Easing.InCubic
            }
        }

        MouseArea { anchors.fill: parent }

        Item {
            anchors.fill: parent

            StackView {
                id: widgetStack
                anchors.fill: parent
                focus: true

                Keys.onEscapePressed: {
                    switchWidget("hidden", "");
                    event.accepted = true;
                }

                onCurrentItemChanged: {
                    if (currentItem) currentItem.forceActiveFocus();
                }

                replaceEnter: Transition {
                    ParallelAnimation {
                        NumberAnimation {
                            property: "opacity"
                            from: 0.0; to: 1.0
                            duration: masterWindow.morphDurationSwitch
                            easing.type: Easing.OutQuint
                        }
                        NumberAnimation {
                            property: "scale"
                            from: 0.98; to: 1.0
                            duration: masterWindow.morphDurationSwitch
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                replaceExit: Transition {
                    ParallelAnimation {
                        NumberAnimation {
                            property: "opacity"
                            from: 1.0; to: 0.0
                            duration: masterWindow.morphDurationSwitch
                            easing.type: Easing.InQuint
                        }
                        NumberAnimation {
                            property: "scale"
                            from: 1.0; to: 0.98
                            duration: masterWindow.morphDurationSwitch
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }

        // ── Window move / resize handles — only while the active widget is
        //    "movable" (movies widget in mpv player mode). Top edge moves the
        //    window; left/right resize width; bottom resizes height. Geometry
        //    snaps back to the layout default when movableNow turns false.
        property point _dragPress
        property real _baseX
        property real _baseY
        property real _baseW
        property real _baseH
        property real _baseAR: 1   // width/height locked during a side/bottom resize
        readonly property int _snapPx: 28

        // Snap a proposed top-left (nx,ny) to the screen edges when close.
        function _snapMove(nx, ny) {
            var sw = masterWindow.width, sh = masterWindow.height, t = _snapPx;
            if (Math.abs(nx) <= t) nx = 0;
            else if (Math.abs(nx + masterWindow.animW - sw) <= t) nx = sw - masterWindow.animW;
            if (Math.abs(ny) <= t) ny = 0;
            else if (Math.abs(ny + masterWindow.animH - sh) <= t) ny = sh - masterWindow.animH;
            return Qt.point(nx, ny);
        }

        MouseArea {   // TOP — move
            enabled: masterWindow.movableNow
            visible: enabled
            z: 300; height: 14
            anchors { top: parent.top; left: parent.left; right: parent.right }
            cursorShape: Qt.SizeAllCursor
            onPressed: (m) => {
                masterWindow.disableMorph = true;
                boundingBox._baseX = masterWindow.animX;
                boundingBox._baseY = masterWindow.animY;
                boundingBox._dragPress = mapToItem(null, m.x, m.y);
            }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nx = boundingBox._baseX + (c.x - boundingBox._dragPress.x);
                var ny = boundingBox._baseY + (c.y - boundingBox._dragPress.y);
                var p = boundingBox._snapMove(nx, ny);
                masterWindow.animX = p.x;
                masterWindow.animY = p.y;
            }
        }
        MouseArea {   // BOTTOM — resize height
            enabled: masterWindow.movableNow
            visible: enabled
            z: 300; height: 12
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right
                      leftMargin: 12; rightMargin: 12 }
            cursorShape: Qt.SizeVerCursor
            onPressed: (m) => {
                masterWindow.disableMorph = true;
                boundingBox._baseW = masterWindow.animW;
                boundingBox._baseH = masterWindow.animH;
                boundingBox._baseAR = masterWindow.animW / masterWindow.animH;
                boundingBox._dragPress = mapToItem(null, m.x, m.y);
            }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nh = Math.max(masterWindow.minWinH, boundingBox._baseH + (c.y - boundingBox._dragPress.y));
                var nw = nh * boundingBox._baseAR;          // keep aspect ratio
                if (nw < masterWindow.minWinW) { nw = masterWindow.minWinW; nh = nw / boundingBox._baseAR; }
                masterWindow.animH = nh; masterWindow.targetH = nh;
                masterWindow.animW = nw; masterWindow.targetW = nw;
            }
        }
        MouseArea {   // RIGHT — resize width
            enabled: masterWindow.movableNow
            visible: enabled
            z: 300; width: 12
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom
                      topMargin: 14; bottomMargin: 12 }
            cursorShape: Qt.SizeHorCursor
            onPressed: (m) => {
                masterWindow.disableMorph = true;
                boundingBox._baseW = masterWindow.animW;
                boundingBox._baseH = masterWindow.animH;
                boundingBox._baseAR = masterWindow.animW / masterWindow.animH;
                boundingBox._dragPress = mapToItem(null, m.x, m.y);
            }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(masterWindow.minWinW, boundingBox._baseW + (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;          // keep aspect ratio
                if (nh < masterWindow.minWinH) { nh = masterWindow.minWinH; nw = nh * boundingBox._baseAR; }
                masterWindow.animW = nw; masterWindow.targetW = nw;
                masterWindow.animH = nh; masterWindow.targetH = nh;
            }
        }
        MouseArea {   // LEFT — resize width from the left edge (moves x)
            enabled: masterWindow.movableNow
            visible: enabled
            z: 300; width: 12
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                      topMargin: 14; bottomMargin: 12 }
            cursorShape: Qt.SizeHorCursor
            onPressed: (m) => {
                masterWindow.disableMorph = true;
                boundingBox._baseX = masterWindow.animX;
                boundingBox._baseW = masterWindow.animW;
                boundingBox._baseH = masterWindow.animH;
                boundingBox._baseAR = masterWindow.animW / masterWindow.animH;
                boundingBox._dragPress = mapToItem(null, m.x, m.y);
            }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = boundingBox._baseW - (c.x - boundingBox._dragPress.x);
                if (nw < masterWindow.minWinW) nw = masterWindow.minWinW;
                var nh = nw / boundingBox._baseAR;          // keep aspect ratio
                if (nh < masterWindow.minWinH) { nh = masterWindow.minWinH; nw = nh * boundingBox._baseAR; }
                // right edge stays put; top stays put
                masterWindow.animX = boundingBox._baseX + (boundingBox._baseW - nw);
                masterWindow.animW = nw; masterWindow.targetW = nw;
                masterWindow.animH = nh; masterWindow.targetH = nh;
            }
        }

        // ── Corner handles — aspect-ratio-locked diagonal resize, driven by the
        //    horizontal drag; the opposite corner stays pinned. ──
        component CornerGrab: MouseArea {
            enabled: masterWindow.movableNow
            visible: enabled
            z: 301; width: 20; height: 20
            function _grab(m) {
                masterWindow.disableMorph = true;
                boundingBox._baseX = masterWindow.animX;
                boundingBox._baseY = masterWindow.animY;
                boundingBox._baseW = masterWindow.animW;
                boundingBox._baseH = masterWindow.animH;
                boundingBox._baseAR = masterWindow.animW / masterWindow.animH;
                boundingBox._dragPress = mapToItem(null, m.x, m.y);
            }
        }

        CornerGrab {   // bottom-right — top-left pinned
            anchors { right: parent.right; bottom: parent.bottom }
            cursorShape: Qt.SizeFDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(masterWindow.minWinW, boundingBox._baseW + (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < masterWindow.minWinH) { nh = masterWindow.minWinH; nw = nh * boundingBox._baseAR; }
                masterWindow.animW = nw; masterWindow.targetW = nw;
                masterWindow.animH = nh; masterWindow.targetH = nh;
            }
        }
        CornerGrab {   // bottom-left — top-right pinned
            anchors { left: parent.left; bottom: parent.bottom }
            cursorShape: Qt.SizeBDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(masterWindow.minWinW, boundingBox._baseW - (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < masterWindow.minWinH) { nh = masterWindow.minWinH; nw = nh * boundingBox._baseAR; }
                masterWindow.animX = boundingBox._baseX + (boundingBox._baseW - nw);
                masterWindow.animW = nw; masterWindow.targetW = nw;
                masterWindow.animH = nh; masterWindow.targetH = nh;
            }
        }
        CornerGrab {   // top-right — bottom-left pinned
            anchors { right: parent.right; top: parent.top }
            cursorShape: Qt.SizeBDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(masterWindow.minWinW, boundingBox._baseW + (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < masterWindow.minWinH) { nh = masterWindow.minWinH; nw = nh * boundingBox._baseAR; }
                masterWindow.animY = boundingBox._baseY + (boundingBox._baseH - nh);
                masterWindow.animW = nw; masterWindow.targetW = nw;
                masterWindow.animH = nh; masterWindow.targetH = nh;
            }
        }
        CornerGrab {   // top-left — bottom-right pinned
            anchors { left: parent.left; top: parent.top }
            cursorShape: Qt.SizeFDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(masterWindow.minWinW, boundingBox._baseW - (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < masterWindow.minWinH) { nh = masterWindow.minWinH; nw = nh * boundingBox._baseAR; }
                masterWindow.animX = boundingBox._baseX + (boundingBox._baseW - nw);
                masterWindow.animY = boundingBox._baseY + (boundingBox._baseH - nh);
                masterWindow.animW = nw; masterWindow.targetW = nw;
                masterWindow.animH = nh; masterWindow.targetH = nh;
            }
        }
    }

    // =========================================================
    // --- WIDGET SWITCHING
    // =========================================================
    function switchWidget(newWidget, arg) {
        delayedClear.stop();

        if (newWidget === "hidden") {
            if (currentActive !== "hidden") {
                masterWindow.morphDuration = masterWindow.exitDuration;
                masterWindow.disableMorph = false;

                masterWindow.animW = 1;
                masterWindow.animH = 1;
                masterWindow.isVisible = false;

                delayedClear.start();
            }
        } else {
            if (currentActive === "hidden" || !masterWindow.isVisible) {
                masterWindow.morphDuration = 230;
                masterWindow.disableMorph = false;

                let t = getLayout(newWidget);
                masterWindow.animX = t.rx;
                masterWindow.animY = t.ry;
                masterWindow.animW = t.w;
                masterWindow.animH = t.h;
                masterWindow.targetW = t.w;
                masterWindow.targetH = t.h;
            } else {
                masterWindow.morphDuration = masterWindow.morphDurationSwitch;
                masterWindow.disableMorph = false;
            }

            Qt.callLater(() => executeSwitch(newWidget, arg, false));
        }
    }

    function executeSwitch(newWidget, arg, immediate) {
        masterWindow.currentActive = newWidget;
        masterWindow.activeArg = arg;

        let t = getLayout(newWidget);
        masterWindow.animX = t.rx;
        masterWindow.animY = t.ry;
        masterWindow.animW = t.w;
        masterWindow.animH = t.h;
        masterWindow.targetW = t.w;
        masterWindow.targetH = t.h;

        let props = {};
        props["notifModel"]   = masterWindow.notifModel;
        props["liveNotifs"]   = masterWindow.liveNotifs;
        props["layoutWidth"]  = t.w;
        props["layoutHeight"] = t.h;
        if (newWidget === "wallpaper") props["widgetArg"] = arg;

        let cached = widgetCache[newWidget];
        if (cached) {
            if (cached.notifModel   !== undefined) cached.notifModel   = masterWindow.notifModel;
            if (cached.liveNotifs   !== undefined) cached.liveNotifs   = masterWindow.liveNotifs;
            if (cached.layoutWidth  !== undefined) cached.layoutWidth  = t.w;
            if (cached.layoutHeight !== undefined) cached.layoutHeight = t.h;
            if (newWidget === "wallpaper" && cached.widgetArg !== undefined) cached.widgetArg = arg;
            if (arg !== "" && cached.activeMode !== undefined) cached.activeMode = arg;

            cached.visible = true;
            if (immediate) {
                widgetStack.replace(cached, {}, StackView.Immediate);
            } else {
                widgetStack.replace(cached, {});
            }
        } else {
            if (immediate) {
                widgetStack.replace(t.comp, props, StackView.Immediate);
            } else {
                widgetStack.replace(t.comp, props);
            }
        }

        let currentItem = widgetStack.currentItem;
        if (currentItem) {
            if (currentItem.targetMasterWidth !== undefined) {
                let dynW = currentItem.targetMasterWidth;
                masterWindow.animW = dynW;
                masterWindow.targetW = dynW;
                masterWindow.animX = Math.floor((masterWindow.width / 2) - (dynW / 2));
            }
            if (currentItem.targetMasterHeight !== undefined) {
                masterWindow.animH = currentItem.targetMasterHeight;
                masterWindow.targetH = currentItem.targetMasterHeight;
            }
        }

        masterWindow.isVisible = true;
    }

    Timer {
        id: delayedClear
        interval: 200
        onTriggered: {
            masterWindow.currentActive = "hidden";
            widgetStack.clear();
            masterWindow.disableMorph = false;
        }
    }
}
