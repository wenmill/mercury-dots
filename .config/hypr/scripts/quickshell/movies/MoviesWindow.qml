// Detached movies window — runs the MovieWidget in its own independent overlay
// window so it coexists with the master shell's popups and the floating window
// (opening anything else never closes it, and vice-versa). The movable / mpv
// aspect-ratio / fullscreen / resize logic is ported from Main.qml, but the input
// mask is ALWAYS just the player box, so this window never blocks clicks to other
// windows — close it with its hotkey, not by clicking off.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../WindowRegistry.js" as Registry

PanelWindow {
    id: moviesWin
    color: "transparent"

    WlrLayershell.namespace: "qs-movies"
    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore
    focusable: !passthrough

    implicitWidth: moviesWin.screen.width
    implicitHeight: moviesWin.screen.height
    visible: isVisible

    property bool isVisible: false
    property bool disableMorph: false
    property int  morphDuration: 230
    property int  exitDuration: 160

    property real animX: 0
    property real animY: 0
    property real animW: 1
    property real animH: 1
    property real targetW: 1
    property real targetH: 1

    readonly property int minWinW: 360
    readonly property int minWinH: 240

    // The widget is built asynchronously (see the Loader below), so this is
    // null for the first moment of the shell's life. Guard every use.
    readonly property Item moviesItem: moviesLoader.item
    readonly property bool movableNow: moviesItem !== null && moviesItem.windowMovable === true

    // Preload once the bar has painted, so the first open is instant without
    // the widget sitting on the startup critical path.
    property bool preloaded: false
    Timer { interval: 1500; running: true; onTriggered: moviesWin.preloaded = true }

    function layout() {
        return Registry.getLayout("movies", 0, 0, moviesWin.width, moviesWin.height, 1.0);
    }
    function openWin() {
        if (moviesWin.isVisible) return;
        var t = layout();
        moviesWin.disableMorph = true;            // place instantly, then fade/scale in
        moviesWin.animX = t.rx; moviesWin.animY = t.ry;
        moviesWin.animW = t.w;  moviesWin.targetW = t.w;
        moviesWin.animH = t.h;  moviesWin.targetH = t.h;
        moviesWin.isVisible = true;
        Qt.callLater(function () { moviesWin.disableMorph = false; });
    }
    function closeWin() { moviesWin.isVisible = false; }
    function toggleWin() { if (moviesWin.isVisible) closeWin(); else openWin(); }

    IpcHandler {
        target: "movieswin"
        function toggle(): void { moviesWin.toggleWin(); }
        function open(): void   { moviesWin.openWin(); }
        function close(): void  { moviesWin.closeWin(); }
        // ALT+F4 (scripts/close_active.sh): the embedded player is a layer
        // surface, so killactive can never reach it — the close keybind asks
        // here first. Returns "closed" when it stopped the player. Passthrough
        // (gaming) is excluded: focus belongs to the game then.
        function closePlayer(): string {
            if (moviesWin.isVisible && !moviesWin.passthrough && moviesItem
                    && moviesItem.currentView === "player") {
                moviesItem.closePlayer();
                return "closed";
            }
            return "no";
        }
        // qs_manager passes (action, target, sub); we only care about the action.
        function handleCommand(cmd: string, t: string, a: string): void {
            if (cmd === "close") moviesWin.closeWin();
            else moviesWin.toggleWin();
        }
    }

    // If the loader hasn't finished, Loader.onLoaded takes the focus instead.
    onIsVisibleChanged: { if (isVisible && !passthrough && moviesItem) moviesItem.forceActiveFocus(); }

    // ── Gaming passthrough (toggled by scripts/overlay_passthrough.sh) ──
    // When on, the window stays visible (video keeps playing) but drops its input
    // mask, so clicks pass through to the game underneath.
    property bool passthrough: false
    // In-process watch (was a cat Process + inotifywait waiter pair); the touch
    // preserves the old watcher's guarantee that the file exists to be watched.
    Process { running: true; command: ["touch", Quickshell.env("HOME") + "/.cache/qs_overlay_passthrough"] }
    FileView {
        id: passView
        path: Quickshell.env("HOME") + "/.cache/qs_overlay_passthrough"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: moviesWin.passthrough = text().trim() === "1"
        onLoadFailed: passRetry.start()
    }
    Timer { id: passRetry; interval: 2000; repeat: false; onTriggered: passView.reload() }

    // Input region:
    //   passthrough → nothing (click-through to the game)
    //   mpv mode    → just the player box (so clicks outside pass to other windows)
    //   browse mode → the whole window, so a click off the widget closes it (popup feel)
    mask: Region { item: moviesWin.passthrough ? null : (moviesWin.movableNow ? boundingBox : fullMask) }
    Item { id: fullMask; anchors.fill: parent }
    // Click off the widget (browse mode only) closes it. Sits under boundingBox, so
    // clicks on the widget itself still reach it.
    MouseArea {
        anchors.fill: parent
        enabled: moviesWin.isVisible && !moviesWin.passthrough && !moviesWin.movableNow
        onClicked: moviesWin.closeWin()
    }

    // Resize the window to the playing movie's aspect ratio.
    function applyVideoAspect() {
        if (!movableNow) return;   // false while moviesItem is null
        if (moviesItem.videoAspect === undefined) return;
        if (moviesItem.playerFullscreen === true) return;
        var a = moviesItem.videoAspect;
        if (!a || a <= 0) return;
        var maxW = moviesWin.width  - 80;
        var maxH = moviesWin.height - 80;
        var w = moviesWin.animW;
        var h = w / a;
        if (h > maxH) { h = maxH; w = h * a; }
        if (w > maxW) { w = maxW; h = w / a; }
        w = Math.max(minWinW, w); h = Math.max(minWinH, h);
        var cx = moviesWin.animX + moviesWin.animW / 2;
        var cy = moviesWin.animY + moviesWin.animH / 2;
        var nx = Math.round(cx - w / 2);
        var ny = Math.round(cy - h / 2);
        nx = Math.max(0, Math.min(nx, moviesWin.width  - w));
        ny = Math.max(0, Math.min(ny, moviesWin.height - h));
        moviesWin.disableMorph = false;
        moviesWin.animX = nx; moviesWin.animY = ny;
        moviesWin.animW = w; moviesWin.targetW = w;
        moviesWin.animH = h; moviesWin.targetH = h;
    }
    function applyPlayerFullscreen() {
        if (!movableNow) return;
        if (moviesItem.playerFullscreen === undefined) return;
        moviesWin.disableMorph = false;
        if (moviesItem.playerFullscreen) {
            moviesWin.animX = 0; moviesWin.animY = 0;
            moviesWin.animW = moviesWin.width;  moviesWin.targetW = moviesWin.width;
            moviesWin.animH = moviesWin.height; moviesWin.targetH = moviesWin.height;
        } else {
            applyVideoAspect();
        }
    }
    Connections {
        target: moviesItem
        ignoreUnknownSignals: true
        function onVideoAspectChanged() { moviesWin.applyVideoAspect(); }
        function onPlayerFullscreenChanged() { moviesWin.applyPlayerFullscreen(); }
        function onWindowMovableChanged() {
            // Leaving movable (mpv) mode: snap back to the layout default size.
            if (!moviesItem.windowMovable) {
                var t = moviesWin.layout();
                moviesWin.disableMorph = false;
                moviesWin.animX = t.rx; moviesWin.animY = t.ry;
                moviesWin.animW = t.w;  moviesWin.targetW = t.w;
                moviesWin.animH = t.h;  moviesWin.targetH = t.h;
            }
        }
    }

    Item {
        id: boundingBox
        x: moviesWin.animX
        y: moviesWin.animY
        width:  moviesWin.animW
        height: moviesWin.animH
        clip: true

        Behavior on x      { enabled: !moviesWin.disableMorph; NumberAnimation { duration: moviesWin.morphDuration; easing.type: Easing.OutCubic } }
        Behavior on y      { enabled: !moviesWin.disableMorph; NumberAnimation { duration: moviesWin.morphDuration; easing.type: Easing.OutCubic } }
        Behavior on width  { enabled: !moviesWin.disableMorph; NumberAnimation { duration: moviesWin.morphDuration; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: !moviesWin.disableMorph; NumberAnimation { duration: moviesWin.morphDuration; easing.type: Easing.OutCubic } }

        opacity: moviesWin.isVisible ? 1.0 : 0.0
        scale:   moviesWin.isVisible ? 1.0 : 0.98
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: moviesWin.isVisible ? Easing.OutCubic : Easing.InCubic } }
        Behavior on scale   { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        // MovieWidget is ~8.3k lines of QML. Building it eagerly cost 2.4s of
        // the shell's startup — measured as the delay before the top bar's
        // layer surface appeared — because this window is created at launch
        // even though it is invisible. Build it asynchronously instead: the bar
        // paints straight away, and a timer starts the widget shortly after so
        // opening movies is still instant. Every reference to `moviesItem`
        // below must tolerate it being null until the loader finishes.
        Loader {
            id: moviesLoader
            anchors.fill: parent
            asynchronous: true
            active: moviesWin.isVisible || moviesWin.preloaded
            // `source:`, not `sourceComponent: MovieWidget {}` — an inline
            // component is compiled together with this file, so the 8.3k lines
            // would still be parsed at startup even though nothing instantiates
            // them. A URL defers the compile until the loader activates.
            source: "MovieWidget.qml"
            // Opening before the preload timer fires activates the loader on
            // demand; focus has to wait until the item actually exists.
            onLoaded: if (moviesWin.isVisible && !moviesWin.passthrough) item.forceActiveFocus()
        }

        // ── Move / resize handles (only in mpv player mode) ──
        property point _dragPress
        property real _baseX
        property real _baseY
        property real _baseW
        property real _baseH
        property real _baseAR: 1
        readonly property int _snapPx: 28
        function _snapMove(nx, ny) {
            var sw = moviesWin.width, sh = moviesWin.height, t = _snapPx;
            if (Math.abs(nx) <= t) nx = 0;
            else if (Math.abs(nx + moviesWin.animW - sw) <= t) nx = sw - moviesWin.animW;
            if (Math.abs(ny) <= t) ny = 0;
            else if (Math.abs(ny + moviesWin.animH - sh) <= t) ny = sh - moviesWin.animH;
            return Qt.point(nx, ny);
        }

        MouseArea {   // TOP — move
            enabled: moviesWin.movableNow; visible: enabled
            z: 300; height: 14
            anchors { top: parent.top; left: parent.left; right: parent.right }
            cursorShape: Qt.SizeAllCursor
            onPressed: (m) => { moviesWin.disableMorph = true; boundingBox._baseX = moviesWin.animX; boundingBox._baseY = moviesWin.animY; boundingBox._dragPress = mapToItem(null, m.x, m.y); }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var p = boundingBox._snapMove(boundingBox._baseX + (c.x - boundingBox._dragPress.x), boundingBox._baseY + (c.y - boundingBox._dragPress.y));
                moviesWin.animX = p.x; moviesWin.animY = p.y;
            }
        }
        MouseArea {   // BOTTOM — resize height (aspect-locked)
            enabled: moviesWin.movableNow; visible: enabled
            z: 300; height: 12
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
            cursorShape: Qt.SizeVerCursor
            onPressed: (m) => { moviesWin.disableMorph = true; boundingBox._baseW = moviesWin.animW; boundingBox._baseH = moviesWin.animH; boundingBox._baseAR = moviesWin.animW / moviesWin.animH; boundingBox._dragPress = mapToItem(null, m.x, m.y); }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nh = Math.max(moviesWin.minWinH, boundingBox._baseH + (c.y - boundingBox._dragPress.y));
                var nw = nh * boundingBox._baseAR;
                if (nw < moviesWin.minWinW) { nw = moviesWin.minWinW; nh = nw / boundingBox._baseAR; }
                moviesWin.animH = nh; moviesWin.targetH = nh; moviesWin.animW = nw; moviesWin.targetW = nw;
            }
        }
        MouseArea {   // RIGHT — resize width (aspect-locked)
            enabled: moviesWin.movableNow; visible: enabled
            z: 300; width: 12
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom; topMargin: 14; bottomMargin: 12 }
            cursorShape: Qt.SizeHorCursor
            onPressed: (m) => { moviesWin.disableMorph = true; boundingBox._baseW = moviesWin.animW; boundingBox._baseH = moviesWin.animH; boundingBox._baseAR = moviesWin.animW / moviesWin.animH; boundingBox._dragPress = mapToItem(null, m.x, m.y); }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(moviesWin.minWinW, boundingBox._baseW + (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < moviesWin.minWinH) { nh = moviesWin.minWinH; nw = nh * boundingBox._baseAR; }
                moviesWin.animW = nw; moviesWin.targetW = nw; moviesWin.animH = nh; moviesWin.targetH = nh;
            }
        }
        MouseArea {   // LEFT — resize width from the left (aspect-locked)
            enabled: moviesWin.movableNow; visible: enabled
            z: 300; width: 12
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 14; bottomMargin: 12 }
            cursorShape: Qt.SizeHorCursor
            onPressed: (m) => { moviesWin.disableMorph = true; boundingBox._baseX = moviesWin.animX; boundingBox._baseW = moviesWin.animW; boundingBox._baseH = moviesWin.animH; boundingBox._baseAR = moviesWin.animW / moviesWin.animH; boundingBox._dragPress = mapToItem(null, m.x, m.y); }
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = boundingBox._baseW - (c.x - boundingBox._dragPress.x);
                if (nw < moviesWin.minWinW) nw = moviesWin.minWinW;
                var nh = nw / boundingBox._baseAR;
                if (nh < moviesWin.minWinH) { nh = moviesWin.minWinH; nw = nh * boundingBox._baseAR; }
                moviesWin.animX = boundingBox._baseX + (boundingBox._baseW - nw);
                moviesWin.animW = nw; moviesWin.targetW = nw; moviesWin.animH = nh; moviesWin.targetH = nh;
            }
        }

        component CornerGrab: MouseArea {
            enabled: moviesWin.movableNow; visible: enabled
            z: 301; width: 20; height: 20
            function _grab(m) {
                moviesWin.disableMorph = true;
                boundingBox._baseX = moviesWin.animX; boundingBox._baseY = moviesWin.animY;
                boundingBox._baseW = moviesWin.animW; boundingBox._baseH = moviesWin.animH;
                boundingBox._baseAR = moviesWin.animW / moviesWin.animH;
                boundingBox._dragPress = mapToItem(null, m.x, m.y);
            }
        }
        CornerGrab {   // bottom-right
            anchors { right: parent.right; bottom: parent.bottom }
            cursorShape: Qt.SizeFDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(moviesWin.minWinW, boundingBox._baseW + (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < moviesWin.minWinH) { nh = moviesWin.minWinH; nw = nh * boundingBox._baseAR; }
                moviesWin.animW = nw; moviesWin.targetW = nw; moviesWin.animH = nh; moviesWin.targetH = nh;
            }
        }
        CornerGrab {   // bottom-left
            anchors { left: parent.left; bottom: parent.bottom }
            cursorShape: Qt.SizeBDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(moviesWin.minWinW, boundingBox._baseW - (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < moviesWin.minWinH) { nh = moviesWin.minWinH; nw = nh * boundingBox._baseAR; }
                moviesWin.animX = boundingBox._baseX + (boundingBox._baseW - nw);
                moviesWin.animW = nw; moviesWin.targetW = nw; moviesWin.animH = nh; moviesWin.targetH = nh;
            }
        }
        CornerGrab {   // top-right
            anchors { right: parent.right; top: parent.top }
            cursorShape: Qt.SizeBDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(moviesWin.minWinW, boundingBox._baseW + (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < moviesWin.minWinH) { nh = moviesWin.minWinH; nw = nh * boundingBox._baseAR; }
                moviesWin.animY = boundingBox._baseY + (boundingBox._baseH - nh);
                moviesWin.animW = nw; moviesWin.targetW = nw; moviesWin.animH = nh; moviesWin.targetH = nh;
            }
        }
        CornerGrab {   // top-left
            anchors { left: parent.left; top: parent.top }
            cursorShape: Qt.SizeFDiagCursor
            onPressed: (m) => _grab(m)
            onPositionChanged: (m) => {
                if (!pressed) return;
                var c = mapToItem(null, m.x, m.y);
                var nw = Math.max(moviesWin.minWinW, boundingBox._baseW - (c.x - boundingBox._dragPress.x));
                var nh = nw / boundingBox._baseAR;
                if (nh < moviesWin.minWinH) { nh = moviesWin.minWinH; nw = nh * boundingBox._baseAR; }
                moviesWin.animX = boundingBox._baseX + (boundingBox._baseW - nw);
                moviesWin.animY = boundingBox._baseY + (boundingBox._baseH - nh);
                moviesWin.animW = nw; moviesWin.targetW = nw; moviesWin.animH = nh; moviesWin.targetH = nh;
            }
        }
    }
}
