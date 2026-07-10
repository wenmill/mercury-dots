// Floating.qml — the floating panel, ported out of Quickshell into a
// LayerShellQt + WebEngine window (see main.cpp).
//
// This is Floating.qml's chrome — edge-peek selector, expand/collapse morph,
// drag-to-edge snapping (left/right/bottom), the rotating selector strip with
// expand+pin buttons, the unified matugen background with orbiting blobs, and
// the precise Wayland input mask (click-through except the strip/panel) — with
// the native chat module swapped for the three web hubs (Obsidian / Hermes /
// Dify) folded straight into the module area. One window, one process.
//
// Quickshell types are gone: PanelWindow→Window (layer role set in C++),
// Scaler→inline s(), MatugenColors→qsColors (loaded in C++), Region mask→
// maskHelper.apply(), Process/execDetached→sh.run().

import QtQuick
import QtQuick.Window
import QtWebEngine

Window {
    id: floatingWidget
    visible: false                       // main.cpp flips this after layer-shell setup
    color: "transparent"
    title: "obsidian-shell"
    width: Screen.width
    height: Screen.height - 60            // clear the 60px topbar (matches Floating.qml)

    // =========================================================
    // --- MATUGEN PALETTE (qsColors injected from C++)
    // =========================================================
    readonly property var c: (typeof qsColors !== "undefined" && qsColors) ? qsColors : ({})
    function col(k, fb) { return c[k] ? c[k] : fb; }
    // `mocha`-compatible accessor object so the ported bindings read unchanged.
    readonly property var mocha: ({
        base:     col("base", "#1e1e2e"),
        text:     col("text", "#cdd6f4"),
        mauve:    col("mauve", "#cba6f7"),
        blue:     col("blue", "#89b4fa"),
        crust:    col("crust", "#11111b"),
        subtext0: col("subtext0", "#a6adc8"),
        overlay0: col("overlay0", "#6c7086"),
        overlay1: col("overlay1", "#7f849c"),
        surface0: col("surface0", "#313244"),
        surface1: col("surface1", "#45475a"),
        surface2: col("surface2", "#585b70")
    })

    // =========================================================
    // --- SCALER (inline; verbatim getScale/s from obsidian.qml)
    // =========================================================
    function getScale() {
        var mw = Screen.width, mh = Screen.height;
        if (mw <= 0 || mh <= 0) return 1.0;
        var r = Math.min(mw / 1920.0, mh / 1080.0);
        var b = (r <= 1.0) ? Math.max(0.35, Math.pow(r, 0.85)) : Math.pow(r, 0.5);
        return b * 1.0;
    }
    readonly property real baseScale: getScale()
    function s(val) { var res = Math.round(val * baseScale); return isNaN(res) ? val : res; }

    // =========================================================
    // --- GAMING PASSTHROUGH (poll ~/.cache/qs_overlay_passthrough)
    // =========================================================
    property bool passthrough: false
    readonly property string passFile: (typeof homeDir !== "undefined" ? homeDir : "") + "/.cache/qs_overlay_passthrough"
    Connections {
        target: passWatch
        function onChanged(content) { floatingWidget.passthrough = (content === "1"); }
    }

    // =========================================================
    // --- COMMAND CHANNEL (keybind drives the panel via a file)
    // =========================================================
    // The launcher writes a one-shot command here (toggle/open/close/notes/
    // hermes/learn); we act on it and clear the file (edge-triggered).
    readonly property string cmdFile: (typeof homeDir !== "undefined" ? homeDir : "") + "/.cache/qs_obsidian_cmd"
    function forceOpen() {
        // Pin while keybind-opened: with no mouse/keyboard focus the focusTracker
        // and hideTimer would otherwise collapse it immediately. isPinned gates all
        // of those, so the panel stays open until the user presses the keybind
        // again (toggle → forceClose unpins). Edge-hover peek is unaffected.
        isPeekVisible = false;
        isPinned = true;
        isSidebarVisible = true;
        isExpanded = true;
        hideTimer.stop();
    }
    function forceClose() {
        isExpanded = false; isSidebarVisible = false; isPinned = false; isPeekVisible = false;
    }
    function applyCommand(cmd) {
        if (cmd === "toggle") { if (isSidebarVisible && isExpanded) forceClose(); else forceOpen(); }
        else if (cmd === "open") forceOpen();
        else if (cmd === "close") forceClose();
        else if (cmd === "notes") { selectView(0); forceOpen(); }
        else if (cmd === "hermes") { selectView(1); forceOpen(); }
        else if (cmd === "learn") { selectView(2); forceOpen(); }
    }
    Connections {
        target: cmdWatch
        function onChanged(content) {
            if (content !== "") { floatingWidget.applyCommand(content); cmdWatch.clear(); }
        }
    }

    // =========================================================
    // --- STATE
    // =========================================================
    property bool isPinned: false
    property bool useGraceTimer: false
    onIsPinnedChanged: if (!isPinned) kickTimer()

    // Authoritative "cursor is over the overlay" flag, driven by the compositor
    // pointer enter/leave on the layer surface (main.cpp SurfaceWatch) — NOT a QML
    // HoverHandler, which can get stuck "hovered" under the in-scene WebEngineView
    // and leave the panel open on mouse-off (the flaky-after-restart case). When
    // it goes false and the panel isn't pinned, we force the close off it below.
    property bool surfacePointerInside: false
    Connections {
        target: surfaceWatch
        function onEntered() {
            floatingWidget.surfacePointerInside = true;
            leaveCloseTimer.stop();
        }
        function onLeft() {
            floatingWidget.surfacePointerInside = false;
            if (!floatingWidget.isPinned && floatingWidget.isSidebarVisible)
                leaveCloseTimer.restart();
        }
    }

    property int hoveredBars: 0

    property int activeIndex: 0
    property bool isExpanded: false
    property bool keepCentered: false
    onIsExpandedChanged: if (isExpanded) { keepCentered = true; hideTimer.stop(); }
    // keepCentered locks the panel to screen-center (no slide) while expanded, but
    // it MUST clear once the panel fully hides — otherwise the sidebar Behavior on
    // x/y stays disabled and the selector snaps open instead of sliding in next
    // time you reach the edge. (Verbatim from Floating.qml's onIsSidebarVisibleChanged.)
    onIsSidebarVisibleChanged: {
        // Keyboard focus follows the panel, and nothing else. The surface maps
        // with KeyboardInteractivityNone (see main.cpp's KeyboardHelper), so at
        // login — when no window holds focus yet — it cannot swallow keystrokes
        // before it has ever been opened. Raise it while the panel is up; drop
        // it on close so the keyboard goes straight back to the focused window.
        kb.setInteractive(isSidebarVisible);

        if (!isSidebarVisible) {
            keepCentered = false;
        } else {
            // Start loading the llama.cpp model the instant the selector peeks open —
            // before the popup is even expanded — so the ~40s cold load is well under
            // way (or done) by the time you reach the Hermes view. Idempotent and
            // self-unloading after idle; see warmHermesModel().
            warmHermesModel();
        }
    }

    property bool isSidebarVisible: false
    property bool isPeekVisible: false
    property bool disableAnim: false
    property bool resizing: false

    property string activeEdge: "left"
    property real currentPos: 0

    // ── Web hub tabs: index 0 Obsidian, 1 Hermes, 2 Dify. ──
    property int tabCount: 3
    readonly property string view: activeIndex === 0 ? "notes" : (activeIndex === 1 ? "hermes" : "learn")

    // =========================================================
    // --- KEYBOARD FOCUS FALLBACK CLOSER (window-level)
    // =========================================================
    // Close when the WINDOW loses focus (the user clicked another app). This
    // must track Window.active, NOT an Item's activeFocus: the old
    // Item{focus:true} version was the scene's initial focus item, so the very
    // first click into a web view after a (re)start stole IN-SCENE focus from
    // it and collapsed the panel — the "first click always closes" bug. Focus
    // moving WITHIN the window (web view, strip) never fires this.
    Connections {
        target: floatingWidget
        function onActiveChanged() {
            if (!floatingWidget.active && !floatingWidget.isPinned) {
                floatingWidget.isExpanded = false;
                hideTimer.restart();
            }
        }
    }

    // =========================================================
    // --- SHORTCUTS
    // =========================================================
    Shortcut { enabled: floatingWidget.isSidebarVisible; sequence: "Tab"; onActivated: { floatingWidget.activeIndex = (floatingWidget.activeIndex + 1) % floatingWidget.tabCount; floatingWidget.selectView(floatingWidget.activeIndex); floatingWidget.kickTimer(); } }
    Shortcut { enabled: floatingWidget.isSidebarVisible; sequence: "Shift+Tab"; onActivated: { floatingWidget.activeIndex = (floatingWidget.activeIndex + floatingWidget.tabCount - 1) % floatingWidget.tabCount; floatingWidget.selectView(floatingWidget.activeIndex); floatingWidget.kickTimer(); } }
    Shortcut { enabled: floatingWidget.isSidebarVisible; sequence: "Return"; onActivated: { floatingWidget.isExpanded = !floatingWidget.isExpanded; floatingWidget.kickTimer(); } }
    Shortcut {
        enabled: floatingWidget.isSidebarVisible
        sequence: "Escape"
        onActivated: {
            if (floatingWidget.isExpanded) { floatingWidget.isExpanded = false; floatingWidget.kickTimer(); }
            else if (!floatingWidget.isPinned) { floatingWidget.isSidebarVisible = false; floatingWidget.isPeekVisible = true; peekHideTimer.restart(); }
        }
    }

    // =========================================================
    // --- GEOMETRY (verbatim from Floating.qml)
    // =========================================================
    property real h_in: s(32)
    property real h_ac: s(112)
    property real itemSpacing: s(10)
    property real buttonSize: s(19)
    property real controlAreaHeight: buttonSize * 2 + s(14)
    property real barOffsetY: (activeEdge === "left" || activeEdge === "bottom") ? (controlAreaHeight + itemSpacing) : 0

    function getTargetY(idx, activeIdx) {
        var y = 0;
        for (var i = 0; i < idx; i++) y += (i === activeIdx ? h_ac : h_in) + itemSpacing;
        return y;
    }

    function evaluateDrag(gpStartX, gpStartY, gpMouseX, gpMouseY) {
        var delta = 0;
        if (activeEdge === "left") delta = gpMouseX - gpStartX;
        else if (activeEdge === "right") delta = gpStartX - gpMouseX;
        else if (activeEdge === "bottom") delta = gpStartY - gpMouseY;
        if (delta > s(30) && !isExpanded) {
            isExpanded = true;
        } else if (delta < -s(30) && (isExpanded || isSidebarVisible)) {
            isExpanded = false;
            if (!isPinned) { isSidebarVisible = false; isPeekVisible = true; peekHideTimer.restart(); }
        }
    }

    // ── Expanded-panel module size: the web hub wants a big content area. ──
    // Width is a FRACTION of the actual screen width (not a scaled pixel count) so
    // it shrinks/grows proportionally on any monitor. ~26% reads clearly narrower
    // than the old s(720) on every resolution.
    property real baseExpandedWidth: Math.round(Screen.width * 0.20)
    property real baseExpandedExtraLength: s(820)
    property real expandedPadding: s(15)
    property real targetExpandedExtraLength: baseExpandedExtraLength
    property real expandedWidth: baseExpandedWidth
    property real expandedExtraLength: baseExpandedExtraLength
    Behavior on expandedWidth { enabled: !floatingWidget.disableAnim; NumberAnimation { duration: 450; easing.type: Easing.OutQuart } }
    Behavior on expandedExtraLength { enabled: !floatingWidget.disableAnim && !floatingWidget.resizing; NumberAnimation { duration: 450; easing.type: Easing.OutQuart } }

    // Size the module: side docks use the base size; bottom dock fills the screen.
    function updateSizes() {
        if (activeEdge === "bottom") {
            var topMargin = s(50), bottomGap = s(6);
            var fillLen = height - topMargin - bottomGap - sidebarW;
            var autoLen = Math.max(baseExpandedExtraLength, fillLen);
            // Honor a user resize (bottomExtraOverride); clamp to a sane min and
            // the screen-fill max so it can't push off the top or collapse away.
            var minLen = s(240);
            var len = bottomExtraOverride >= 0
                ? Math.max(minLen, Math.min(autoLen, bottomExtraOverride))
                : autoLen;
            targetExpandedExtraLength = len;
            expandedWidth = baseExpandedWidth;
            expandedExtraLength = len;
        } else {
            // Sides: the strip stays content-sized; the expanded module popup grows to
            // fill the screen height minus a fixed margin at top and bottom. panelH =
            // baseSidebarH + extra, and the panel is centred when expanded, so picking
            // extra = (height - 2·margin) - baseSidebarH lands the module exactly
            // sideModuleMargin away from the topbar and the screen bottom.
            var len = Math.max(s(120), height - 2 * sideModuleMargin - baseSidebarH);
            targetExpandedExtraLength = len;
            expandedWidth = baseExpandedWidth;
            expandedExtraLength = len;
        }
    }
    onActiveEdgeChanged: updateSizes()
    Component.onCompleted: {
        updateSizes(); maskHelper.apply(maskFlat);
        passWatch.watch(passFile, 400);
        cmdWatch.watch(cmdFile, 150);
        // Preload ALL three web hubs at startup so switching/opening is instant — no
        // first-open load wait. Obsidian (:8765) loads unconditionally (see its url
        // below); here we bring up the Hermes dashboard server and bind the Hermes +
        // Dify URLs so those render in the background too. The views stay loaded for
        // the session (no about:blank parking), and are simply hidden when collapsed.
        // NB: this only preloads the web UIs — it does NOT warm the llama.cpp model
        // (that stays on-demand via warmHermesModel(), preserving the VRAM behaviour).
        ensureHermesServer();   // starts :9119 if needed, sets hermesLoaded → binds Hermes URL
        learnLoaded = true;     // binds the Dify URL so it loads now too
    }

    property real expandProgress: isExpanded ? 1.0 : 0.0
    Behavior on expandProgress { enabled: !floatingWidget.disableAnim; NumberAnimation { duration: 200; easing.type: Easing.OutQuart } }
    property real visibleProgress: isSidebarVisible ? 1.0 : 0.0
    Behavior on visibleProgress { enabled: !floatingWidget.disableAnim; NumberAnimation { duration: 300; easing.type: Easing.OutExpo } }

    property real currentExtraWidth: (expandedWidth + expandedPadding) * expandProgress
    property real currentExtraLength: expandedExtraLength * expandProgress
    property real sidebarW: s(35)

    // Gap the expanded MODULE popup keeps from the topbar (top of the surface) and
    // the screen bottom on the side docks — when expanded the panel grows to fill the
    // window height minus this margin at each end, and the panel is centred, so the
    // top and bottom gaps are identical. Expressed as a FRACTION of the window height
    // (not a scaled pixel count) so the gap is proportionally the same on any monitor.
    // The selector strip itself stays its natural content size (below).
    property real sideModuleMargin: Math.round(height * 0.025)

    // The selector strip's natural (content) height: control area + the pill stack.
    property real baseSidebarH: {
        var count = tabCount;
        var activeTabH = count > 0 ? h_ac : 0;
        var inactiveTabsH = Math.max(0, count - 1) * h_in;
        var tabsSpacing = Math.max(0, count - 1) * itemSpacing;
        var controlSpacing = count > 0 ? itemSpacing : 0;
        var margins = s(16);
        return controlAreaHeight + controlSpacing + activeTabH + inactiveTabsH + tabsSpacing + margins;
    }

    // Bottom popup matches the side docks' total width — web width PLUS the
    // sidebarW the sides spend on their selector strip — so every dock opens
    // the same overall size.
    property real panelW: activeEdge === "bottom"
        ? Math.max(sidebarW + currentExtraWidth, baseSidebarH)
        : (sidebarW + currentExtraWidth)
    property real panelH: activeEdge === "bottom"
        ? (sidebarW + currentExtraLength)
        : (baseSidebarH + currentExtraLength)

    // ── Bottom-dock resize handle + web cutoff (bottom edge ONLY) ───────────
    // The bottom dock is a vertical column: selector strip pinned at the TOP,
    // web hub below. A drag bar sits ABOVE the selector; dragging it up/down
    // changes the popup height, and the web content is inset so it stops at the
    // selector instead of running full-bleed under it. (Left/right unaffected.)
    property real bottomResizeBarH: s(14)
    property real bottomSelectorBand: sidebarW      // selector strip thickness (bottom)
    // User height override for the bottom popup: -1 = auto (fill screen). Set by
    // the resize drag; clamped in updateSizes() to [min, screen-fill].
    property real bottomExtraOverride: -1
    // How far the web content is pushed down (bottom dock only) so it's cut off
    // at the selector, leaving room for the resize bar + selector strip on top.
    // Web starts exactly at the selector band's bottom edge. The pill visuals
    // (~s(19) tall) are centered in the s(35) band, so this leaves a small
    // ~s(7) breathing gap between the pills and the first terminal row —
    // deliberate ("give it a small margin"); the in-page padding is zeroed by
    // hermes_zen.js, so this inset is the ONLY spacing knob.
    property real bottomWebTopInset: activeEdge === "bottom"
        ? (bottomResizeBarH + bottomSelectorBand) : 0
    // Hermes-only top inset: hermes_zen.js zeroes the chat page's own top
    // padding (the app shell reserved 52.5px for its zen-hidden header), so
    // unlike Obsidian/Dify the Hermes page brings NO spacing of its own. On the
    // bottom dock the selector inset (s(49)) covers it; on the side docks clear
    // the native hamburger/new-chat buttons (top s(10), height s(34) → bottom
    // s(44)) with a small gap so the chat bar starts below them, not behind.
    property real hermesWebTopInset: activeEdge === "bottom"
        ? bottomWebTopInset : s(48)

    // =========================================================
    // --- CLAMPED CENTERING
    // =========================================================
    function safeClamp(pos, size, margin) {
        var minCenter = margin, maxCenter = size - margin;
        if (minCenter <= maxCenter) return Math.max(minCenter, Math.min(maxCenter, pos));
        var ratio = Math.max(0, Math.min(1, pos / size));
        return minCenter + ratio * (maxCenter - minCenter);
    }
    property real targetEdgeMargin: {
        var length = baseSidebarH;
        if (isExpanded) length += targetExpandedExtraLength;
        return (length / 2) + s(5);
    }
    property real targetEdgeMarginX: (panelW / 2) + s(5)
    property real clampedCenterX: safeClamp(currentPos, width, activeEdge === "bottom" ? targetEdgeMarginX : targetEdgeMargin)
    property real clampedCenterY: safeClamp(currentPos, height, targetEdgeMargin)

    property real sidebarTargetX: {
        if (activeEdge === "left")   return 0;
        if (activeEdge === "right")  return width - panelW;
        if (activeEdge === "bottom") return clampedCenterX - panelW / 2;
        return 0;
    }
    property real sidebarTargetY: {
        if (activeEdge === "left" || activeEdge === "right")
            return (isExpanded || keepCentered) ? (height - panelH) / 2 : (clampedCenterY - panelH / 2);
        if (activeEdge === "bottom") return height - s(6) - panelH;
        return 0;
    }

    // Fully-expanded geometry (as if expandProgress == 1), used to PIN the web
    // content so it never moves/resizes while the panel grows. The panel
    // (sidebarContainer) grows AND its top drifts (sidebarTargetY = (height -
    // panelH)/2 recomputes every frame as panelH grows), so anything anchored to
    // it travels with it. The web views instead lock onto THIS rect and let the
    // growing, clipped container reveal them in place. Mirrors panelW/panelH and
    // sidebarTargetX/Y but with the expanded extents at full value.
    readonly property real finalExtraWidth:  expandedWidth + expandedPadding
    readonly property real finalExtraLength: expandedExtraLength
    readonly property real finalPanelW: activeEdge === "bottom"
        ? Math.max(sidebarW + finalExtraWidth, baseSidebarH)
        : (sidebarW + finalExtraWidth)
    readonly property real finalPanelH: activeEdge === "bottom"
        ? (sidebarW + finalExtraLength)
        : (baseSidebarH + finalExtraLength)
    readonly property real finalPanelX: {
        if (activeEdge === "left")   return 0;
        if (activeEdge === "right")  return width - finalPanelW;
        if (activeEdge === "bottom") return clampedCenterX - finalPanelW / 2;
        return 0;
    }
    readonly property real finalPanelY: {
        if (activeEdge === "left" || activeEdge === "right") return (height - finalPanelH) / 2;
        if (activeEdge === "bottom") return height - s(6) - finalPanelH;
        return 0;
    }

    // =========================================================
    // --- WAYLAND INPUT MASK (replaces Quickshell Region)
    // =========================================================
    // Flat [x,y,w,h,...] union: 1px edge lines (so slamming the cursor to a
    // screen edge triggers the peek), plus the peek bar and the expanded panel
    // when visible. Empty in passthrough → fully click-through.
    property var maskFlat: {
        if (passthrough) return [];
        var b = s(15);
        var e = s(3);   // edge-trigger strip width (a few px for reliable hit-testing)
        var arr = [0, 0, e, height,  width - e, 0, e, height,  0, height - e, width, e];
        if (isPeekVisible)
            arr = arr.concat([peekBar.x - b, peekBar.y - b, peekBar.width + 2 * b, peekBar.height + 2 * b]);
        if (isSidebarVisible)
            arr = arr.concat([sidebarContainer.x - b, sidebarContainer.y - b, sidebarContainer.width + 2 * b, sidebarContainer.height + 2 * b]);
        return arr;
    }
    onMaskFlatChanged: maskHelper.apply(maskFlat)
    // The platform (Wayland) window doesn't exist until main.cpp shows it, which
    // happens AFTER Component.onCompleted — so an early setMask is lost. Re-apply
    // on a steady tick (the C++ side dedups, so this is cheap) to guarantee the
    // input region is installed once the surface is live, and to recover it after
    // any surface reconfigure.
    Timer {
        interval: 500; repeat: true; running: true
        onTriggered: maskHelper.apply(floatingWidget.maskFlat)
    }

    // =========================================================
    // --- EDGE TRANSITION STATE MACHINE
    // =========================================================
    property string pendingEdge: ""
    property real pendingPos: 0
    property bool pendingWasExpanded: false
    property string pendingMode: ""

    Timer {
        id: edgeTransitionTimer
        interval: 350
        onTriggered: {
            floatingWidget.disableAnim = true;
            floatingWidget.activeEdge = floatingWidget.pendingEdge;
            floatingWidget.currentPos = floatingWidget.pendingPos;
            teleportTimer.restart();
        }
    }
    Timer {
        id: teleportTimer
        interval: 32
        onTriggered: {
            floatingWidget.disableAnim = false;
            if (floatingWidget.pendingMode === "sidebar") {
                floatingWidget.isSidebarVisible = true;
                floatingWidget.isExpanded = floatingWidget.pendingWasExpanded;
                floatingWidget.isPeekVisible = false;
                hideTimer.restart();
            } else if (floatingWidget.pendingMode === "peek") {
                floatingWidget.isPeekVisible = true;
                floatingWidget.isSidebarVisible = false;
                floatingWidget.isExpanded = false;
            }
            floatingWidget.pendingMode = "";
        }
    }

    function showPeek(edge, pos) {
        if (isPinned || isSidebarVisible || pendingMode === "sidebar") return;
        if (activeEdge !== edge) {
            if (isPeekVisible || edgeTransitionTimer.running) {
                pendingEdge = edge; pendingPos = pos; pendingMode = "peek";
                if (!edgeTransitionTimer.running) { isPeekVisible = false; edgeTransitionTimer.restart(); }
            } else {
                disableAnim = true; activeEdge = edge; currentPos = pos; pendingMode = "peek"; teleportTimer.restart();
            }
            return;
        } else if (edgeTransitionTimer.running) {
            edgeTransitionTimer.stop(); pendingMode = "";
        }
        currentPos = pos; isPeekVisible = true; peekHideTimer.stop();
    }

    function showSidebar(edge, pos) {
        if (isPinned) return;
        if (activeEdge !== edge) {
            if (isSidebarVisible || isExpanded || edgeTransitionTimer.running) {
                pendingEdge = edge; pendingPos = pos; pendingMode = "sidebar";
                if (!edgeTransitionTimer.running) {
                    pendingWasExpanded = isExpanded; isExpanded = false; isSidebarVisible = false; isPeekVisible = false;
                    edgeTransitionTimer.restart();
                }
            } else {
                disableAnim = true; activeEdge = edge; currentPos = pos; pendingMode = "sidebar"; pendingWasExpanded = false; teleportTimer.restart();
            }
            return;
        } else if (edgeTransitionTimer.running) {
            edgeTransitionTimer.stop();
            if (pendingMode === "sidebar") isExpanded = pendingWasExpanded;
            pendingMode = "";
        }
        currentPos = pos; isSidebarVisible = true; isPeekVisible = false; hideTimer.restart();
    }

    function kickTimer() {
        if (isPinned) return;
        if ((typeof mainHoverTracker !== "undefined" && mainHoverTracker.hovered) ||
            (sidebarDragArea.containsMouse || sidebarDragArea.pressed) ||
            (gridMouseArea.containsMouse || gridMouseArea.pressed) ||
            (peekMouse.containsMouse || peekMouse.pressed) ||
            pinMouse.containsMouse || expandMouse.containsMouse ||
            hoveredBars > 0) return;
        hideTimer.restart();
    }

    Timer {
        id: peekHideTimer
        interval: 50
        onTriggered: {
            if (peekMouse.pressed) { peekHideTimer.restart(); return; }
            if (!peekMouse.containsMouse && !leftEdge.containsMouse && !rightEdge.containsMouse && !bottomEdge.containsMouse)
                floatingWidget.isPeekVisible = false;
        }
    }
    Timer {
        id: hideTimer
        interval: floatingWidget.useGraceTimer ? 3000 : 800
        onTriggered: {
            if (floatingWidget.isPinned) return;
            if (sidebarDragArea.pressed || peekMouse.pressed || gridMouseArea.pressed) { hideTimer.restart(); return; }
            if (floatingWidget.isExpanded) { floatingWidget.isExpanded = false; closeTabTimer.restart(); }
            else floatingWidget.isSidebarVisible = false;
            floatingWidget.useGraceTimer = false;
        }
    }
    // Force-close when the compositor reports the cursor has left the overlay
    // (SurfaceWatch.left). This is the authoritative mouse-off path and, unlike
    // closeTabTimer, does NOT consult any HoverHandler (which can be stuck) — so
    // an unpinned panel ALWAYS closes on mouse-off, even right after a restart.
    // The short delay tolerates a quick flick out-and-back (Enter cancels it).
    Timer {
        id: leaveCloseTimer
        interval: 350
        onTriggered: {
            if (floatingWidget.isPinned) return;
            if (floatingWidget.surfacePointerInside) return;   // came back
            if (sidebarDragArea.pressed || peekMouse.pressed || gridMouseArea.pressed) { leaveCloseTimer.restart(); return; }
            floatingWidget.isExpanded = false;
            floatingWidget.isSidebarVisible = false;
            floatingWidget.useGraceTimer = false;
        }
    }
    Timer {
        id: closeTabTimer
        interval: 470
        onTriggered: {
            if (floatingWidget.isPinned || floatingWidget.isExpanded) return;
            if ((typeof mainHoverTracker !== "undefined" && mainHoverTracker.hovered) || floatingWidget.hoveredBars > 0) return;
            floatingWidget.isSidebarVisible = false;
        }
    }
    Timer {
        id: peekShowTimer
        interval: 300
        property string pendingShowEdge: ""
        property real pendingShowPos: 0
        onTriggered: floatingWidget.showSidebar(pendingShowEdge, pendingShowPos)
    }

    // =========================================================
    // --- HUB RENDERER DISCARD (memory reclaim while closed)
    // =========================================================
    // The three preloaded hubs hold ~3 GB of renderer memory while the panel
    // sits closed. After the panel has been closed for this long, move the
    // (hidden) views to the Discarded lifecycle state — Chromium drops their
    // renderer processes entirely. The URL and profile stay bound, so the
    // next open implicitly re-activates and reloads the view (the userScripts
    // re-inject at DocumentCreation, and the retry bursts fire off
    // onWebShownChanged as on any open) — the cost is a brief reload on the
    // first open after a long idle instead of gigabytes held around the clock.
    Timer {
        id: hubDiscardTimer
        interval: 10 * 60 * 1000
        running: !floatingWidget.isSidebarVisible && !floatingWidget.isExpanded
                 && floatingWidget.expandProgress < 0.01
        onTriggered: {
            webObsidian.lifecycleState = WebEngineView.LifecycleState.Discarded;
            webHermes.lifecycleState  = WebEngineView.LifecycleState.Discarded;
            webDify.lifecycleState    = WebEngineView.LifecycleState.Discarded;
        }
    }

    // =========================================================
    // --- EDGE TRIGGERS
    // =========================================================
    Item {
        id: mainHitArea
        anchors.fill: parent

        MouseArea {
            id: leftEdge
            x: 0; y: 0; width: floatingWidget.s(12); height: floatingWidget.height
            hoverEnabled: true
            onEntered: {
                peekHideTimer.stop();
                if (floatingWidget.isSidebarVisible || floatingWidget.pendingMode === "sidebar") floatingWidget.showSidebar("left", mouseY + y);
                else if (floatingWidget.isPeekVisible) floatingWidget.showPeek("left", mouseY + y);
                else { peekShowTimer.pendingShowEdge = "left"; peekShowTimer.pendingShowPos = mouseY + y; peekShowTimer.restart(); }
            }
            onPositionChanged: mouse => {
                if (floatingWidget.isSidebarVisible || floatingWidget.pendingMode === "sidebar") floatingWidget.showSidebar("left", mouse.y + y);
                else if (floatingWidget.isPeekVisible) floatingWidget.showPeek("left", mouse.y + y);
                else peekShowTimer.pendingShowPos = mouse.y + y;
            }
            onExited: { peekShowTimer.stop(); peekHideTimer.restart(); }
        }
        MouseArea {
            id: rightEdge
            x: floatingWidget.width - floatingWidget.s(12); y: 0; width: floatingWidget.s(12); height: floatingWidget.height
            hoverEnabled: true
            onEntered: {
                peekHideTimer.stop();
                if (floatingWidget.isSidebarVisible || floatingWidget.pendingMode === "sidebar") floatingWidget.showSidebar("right", mouseY + y);
                else if (floatingWidget.isPeekVisible) floatingWidget.showPeek("right", mouseY + y);
                else { peekShowTimer.pendingShowEdge = "right"; peekShowTimer.pendingShowPos = mouseY + y; peekShowTimer.restart(); }
            }
            onPositionChanged: mouse => {
                if (floatingWidget.isSidebarVisible || floatingWidget.pendingMode === "sidebar") floatingWidget.showSidebar("right", mouse.y + y);
                else if (floatingWidget.isPeekVisible) floatingWidget.showPeek("right", mouse.y + y);
                else peekShowTimer.pendingShowPos = mouse.y + y;
            }
            onExited: { peekShowTimer.stop(); peekHideTimer.restart(); }
        }
        MouseArea {
            id: bottomEdge
            x: 0; y: floatingWidget.height - floatingWidget.s(12); width: floatingWidget.width; height: floatingWidget.s(12)
            hoverEnabled: true
            onEntered: {
                peekHideTimer.stop();
                if (floatingWidget.isSidebarVisible || floatingWidget.pendingMode === "sidebar") floatingWidget.showSidebar("bottom", mouseX + x);
                else if (floatingWidget.isPeekVisible) floatingWidget.showPeek("bottom", mouseX + x);
                else { peekShowTimer.pendingShowEdge = "bottom"; peekShowTimer.pendingShowPos = mouseX + x; peekShowTimer.restart(); }
            }
            onPositionChanged: mouse => {
                if (floatingWidget.isSidebarVisible || floatingWidget.pendingMode === "sidebar") floatingWidget.showSidebar("bottom", mouse.x + x);
                else if (floatingWidget.isPeekVisible) floatingWidget.showPeek("bottom", mouse.x + x);
                else peekShowTimer.pendingShowPos = mouse.x + x;
            }
            onExited: { peekShowTimer.stop(); peekHideTimer.restart(); }
        }
    }

    // =========================================================
    // --- PEEK BAR (DRAG HANDLE)
    // =========================================================
    Rectangle {
        id: peekBar
        width: floatingWidget.activeEdge === "bottom" ? Math.max(floatingWidget.s(20), floatingWidget.baseSidebarH - floatingWidget.s(20)) : floatingWidget.s(12)
        height: floatingWidget.activeEdge === "bottom" ? floatingWidget.s(12) : Math.max(floatingWidget.s(20), floatingWidget.baseSidebarH - floatingWidget.s(20))
        radius: floatingWidget.s(6)
        color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 1.0)
        border.width: 0
        opacity: (floatingWidget.isPeekVisible && !floatingWidget.isSidebarVisible) ? (peekMouse.containsMouse || peekMouse.pressed ? 1.0 : 0.6) : 0.0
        scale: floatingWidget.isPeekVisible ? 1.0 : 0.6
        Behavior on opacity { NumberAnimation { duration: 250 } }
        Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }

        property real visualDragOffset: {
            if (!peekMouse.pressed) return 0;
            return Math.max(-floatingWidget.s(15), Math.min(peekMouse.currentDragDelta, floatingWidget.s(15)));
        }
        x: {
            if (floatingWidget.activeEdge === "left") return (floatingWidget.isPeekVisible ? floatingWidget.s(3) : -width - floatingWidget.s(10)) + visualDragOffset;
            if (floatingWidget.activeEdge === "right") return (floatingWidget.isPeekVisible ? floatingWidget.width - width - floatingWidget.s(3) : floatingWidget.width + floatingWidget.s(10)) - visualDragOffset;
            if (floatingWidget.activeEdge === "bottom") return clampedCenterX - width / 2;
            return 0;
        }
        y: {
            if (floatingWidget.activeEdge === "bottom") return (floatingWidget.isPeekVisible ? floatingWidget.height - height - floatingWidget.s(3) : floatingWidget.height + floatingWidget.s(10)) - visualDragOffset;
            if (floatingWidget.activeEdge === "left" || floatingWidget.activeEdge === "right") return clampedCenterY - height / 2;
            return 0;
        }
        Behavior on x { enabled: !floatingWidget.disableAnim && !peekMouse.pressed; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }
        Behavior on y { enabled: !floatingWidget.disableAnim && !peekMouse.pressed; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }

        Rectangle {
            anchors.centerIn: parent
            width: floatingWidget.activeEdge === "bottom" ? floatingWidget.s(30) : floatingWidget.s(4)
            height: floatingWidget.activeEdge === "bottom" ? floatingWidget.s(4) : floatingWidget.s(30)
            radius: floatingWidget.s(2)
            color: Qt.darker(mocha.mauve, 1.8)
        }

        MouseArea {
            id: peekMouse
            anchors.fill: parent
            anchors.margins: -floatingWidget.s(15)
            hoverEnabled: true
            enabled: floatingWidget.isPeekVisible || pressed
            property real startGlobalX: 0
            property real startGlobalY: 0
            property real currentDragDelta: 0
            onEntered: { floatingWidget.isPeekVisible = true; peekHideTimer.stop(); }
            onExited: { if (!pressed) peekHideTimer.restart(); }
            onPressed: mouse => {
                var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                startGlobalX = gp.x; startGlobalY = gp.y; currentDragDelta = 0;
                floatingWidget.useGraceTimer = true;
            }
            onPositionChanged: mouse => {
                if (!pressed) return;
                var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                var delta = 0;
                if (floatingWidget.activeEdge === "left") delta = gp.x - startGlobalX;
                else if (floatingWidget.activeEdge === "right") delta = startGlobalX - gp.x;
                else if (floatingWidget.activeEdge === "bottom") delta = startGlobalY - gp.y;
                currentDragDelta = delta;
                if (delta > floatingWidget.s(15) && !floatingWidget.isExpanded) {
                    floatingWidget.showSidebar(floatingWidget.activeEdge, floatingWidget.currentPos);
                    floatingWidget.isExpanded = true;
                } else if (delta < -floatingWidget.s(10) && floatingWidget.isPeekVisible) {
                    floatingWidget.isPeekVisible = false;
                }
            }
            onReleased: { currentDragDelta = 0; peekHideTimer.restart(); }
            onClicked: floatingWidget.showSidebar(floatingWidget.activeEdge, floatingWidget.currentPos)
        }
    }

    // =========================================================
    // --- SIDEBAR CONTAINER (the panel)
    // =========================================================
    Item {
        id: sidebarContainer
        width: floatingWidget.panelW
        height: floatingWidget.panelH
        x: {
            if (floatingWidget.isSidebarVisible) return floatingWidget.sidebarTargetX;
            if (floatingWidget.activeEdge === "left") return -width - floatingWidget.s(20);
            if (floatingWidget.activeEdge === "right") return floatingWidget.width + floatingWidget.s(20);
            return floatingWidget.sidebarTargetX;
        }
        y: {
            if (floatingWidget.isSidebarVisible) return floatingWidget.sidebarTargetY;
            if (floatingWidget.activeEdge === "bottom") return floatingWidget.height + floatingWidget.s(20);
            return floatingWidget.sidebarTargetY;
        }
        // Disable the slide off isExpanded directly (not just keepCentered): keepCentered
        // is set in onIsExpandedChanged, which RACES the sidebarTarget x/y bindings that
        // re-evaluate to screen-center on open. When the binding wins that race the panel
        // animates its 350ms slide to center instead of snapping there — and the web view
        // reveals (expandProgress>0.97) mid-slide, so the page briefly appears offset
        // ("up / to the edge") before settling. Keying the disable on isExpanded (the
        // actual trigger) makes the centered position apply synchronously, no race.
        Behavior on x { enabled: !floatingWidget.disableAnim && !floatingWidget.keepCentered && !floatingWidget.isExpanded; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }
        Behavior on y { enabled: !floatingWidget.disableAnim && !floatingWidget.keepCentered && !floatingWidget.isExpanded; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }

        Item {
            id: morphOrigin
            anchors.fill: parent

            HoverHandler {
                id: mainHoverTracker
                onHoveredChanged: {
                    if (hovered) { floatingWidget.useGraceTimer = false; hideTimer.stop(); }
                    else floatingWidget.kickTimer();
                }
            }

            // ── Unified matugen background with orbiting blobs (verbatim) ──
            Rectangle {
                id: unifiedBg
                anchors.fill: parent
                radius: floatingWidget.s(15)
                color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.95)
                border.width: 1
                border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.08)
                opacity: floatingWidget.expandProgress
                visible: floatingWidget.expandProgress > 0.01
                clip: true

                // Timer-stepped at 20fps instead of a per-frame NumberAnimation:
                // the blobs sweep two revolutions per 76s, well under a pixel per
                // 50ms step, and the render loop wakes 20x/s instead of every
                // vsync while the panel is open.
                property real orbitAngle: 0
                Timer {
                    interval: 50; repeat: true
                    running: floatingWidget.expandProgress > 0.05 && !floatingWidget.resizing
                    onTriggered: unifiedBg.orbitAngle = (unifiedBg.orbitAngle + 4 * Math.PI * 50 / 76000) % (4 * Math.PI)
                }
                Rectangle {
                    width: parent.width * 0.8; height: width; radius: width / 2
                    x: (parent.width / 2 - width / 2) + Math.cos(unifiedBg.orbitAngle * 2) * floatingWidget.s(150)
                    y: (parent.height / 2 - height / 2) + Math.sin(unifiedBg.orbitAngle * 2) * floatingWidget.s(100)
                    opacity: 0.08; color: mocha.mauve
                }
                Rectangle {
                    width: parent.width * 0.9; height: width; radius: width / 2
                    x: (parent.width / 2 - width / 2) + Math.sin(unifiedBg.orbitAngle * 1.5) * floatingWidget.s(-150)
                    y: (parent.height / 2 - height / 2) + Math.cos(unifiedBg.orbitAngle * 1.5) * floatingWidget.s(-100)
                    opacity: 0.06; color: mocha.blue
                }
            }

            // ── Selector strip backing nub (fades out as the panel expands) ──
            Rectangle {
                id: morphingBackground
                anchors.fill: staticContentWrapper
                anchors.margins: -floatingWidget.s(4)
                rotation: floatingWidget.activeEdge === "bottom" ? -90 : 0
                transformOrigin: Item.Center
                radius: floatingWidget.s(15)
                color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.95 * (1.0 - floatingWidget.expandProgress))
                border.width: 1
                border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.08 * (1.0 - floatingWidget.expandProgress))

                MouseArea {
                    id: sidebarDragArea
                    anchors.fill: parent
                    anchors.margins: floatingWidget.isExpanded ? -floatingWidget.s(60) : -floatingWidget.s(15)
                    hoverEnabled: true
                    enabled: floatingWidget.isSidebarVisible
                    property real startGlobalX: 0
                    property real startGlobalY: 0
                    onEntered: hideTimer.stop()
                    onExited: { if (!pressed && !gridMouseArea.containsMouse) floatingWidget.kickTimer(); }
                    onPressed: mouse => {
                        var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                        startGlobalX = gp.x; startGlobalY = gp.y;
                        floatingWidget.useGraceTimer = true;
                    }
                    onPositionChanged: mouse => {
                        if (!pressed) return;
                        var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                        floatingWidget.evaluateDrag(startGlobalX, startGlobalY, gp.x, gp.y);
                    }
                    onReleased: { if (!containsMouse) floatingWidget.kickTimer(); }
                }
            }

            // ── MODULE AREA: the three web hubs ──
            Item {
                id: expandedContainer
                // Fill the ENTIRE panel so the web hub spans the whole matugen
                // background. The selector strip (staticContentWrapper, declared
                // after this) overlays on top — the web view runs UNDER it (clicks
                // behind the selector are intentionally blocked). Previously this
                // was inset to currentExtraWidth so it sat BESIDE the selector;
                // now the webFrame's leftMargin/rightMargin keep the web content
                // flush against the selector side while the rest fills the bg.
                x: 0
                y: 0
                width: parent.width
                height: parent.height
                opacity: floatingWidget.expandProgress
                clip: true

                // Inset frame; flush against the selector strip on its side.
                Item {
                    id: webFrame
                    // PINNED to the final expanded rect in SCREEN space. Size is the
                    // fully-expanded size (constant), and x/y cancel the parent
                    // container's current position so webFrame stays at
                    // finalPanelX/finalPanelY on screen for the whole open animation.
                    // expandedContainer (clip:true) grows over it and reveals more of it
                    // each frame — so the web content lays out ONCE at final size and
                    // never moves or reflows while the panel grows. (Previously this was
                    // anchors.fill:parent, so it grew AND drifted up with the centered
                    // grow of sidebarContainer, which is what made the page slide into
                    // place on open.) The webui still fills all four edges of the popup
                    // at full size; the selector strip overlays on top.
                    width:  floatingWidget.finalPanelW
                    height: floatingWidget.finalPanelH
                    x: floatingWidget.finalPanelX - sidebarContainer.x
                    y: floatingWidget.finalPanelY - sidebarContainer.y
                    visible: floatingWidget.expandProgress > 0.01

                    WebEngineProfile {
                        id: hubProfile; storageName: "ignis-obsidian"
                        offTheRecord: false; persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
                    }
                    // Each web view's OWN visible must drop when the panel collapses:
                    // a WebEngineView subsurface ignores parent opacity/visibility and
                    // keeps compositing its last frame where it was (Wayland quirk), so
                    // gate on expandProgress to actually tear the subsurface down.
                    readonly property bool webShown: floatingWidget.expandProgress > 0.5
                    // The web content is now PINNED to the final rect (webFrame above), so
                    // it never moves or reflows while the panel grows — there's nothing to
                    // wait for position-wise, and the old size+settle guards are gone. The
                    // content is also clipped to the growing background (expandedContainer
                    // clip:true), so it's only ever visible where the background already
                    // covers it. This light progress threshold just gives the fade a beat
                    // after the grow starts; the 80ms opacity Behavior on each view softens
                    // it. Lower toward 0 to reveal earlier, raise toward 1.0 for later.
                    readonly property bool webReveal: floatingWidget.expandProgress > 0.15
                    // Keep the ACTIVE view RENDERED (so Chromium actually paints it) from the
                    // moment the panel starts opening. The views sit at full size but
                    // visibilityState=hidden while closed, so they only paint their first
                    // frame when shown — light Obsidian does that instantly, but the heavier
                    // Hermes/Dify SPAs need a beat, which made them feel slower to open.
                    // Painting them early (while still transparent — opacity/webReveal keeps
                    // them invisible until the background has grown to cover them) means the
                    // reveal is instant for every module, not just Obsidian.
                    readonly property bool webPaint: floatingWidget.expandProgress > 0.02
                    // Re-run the transparency/gap injection EVERY time the panel opens
                    // (not just on first load): when the view becomes shown, kick a
                    // fresh retry burst so the CSS + sweep re-apply against whatever DOM
                    // Obsidian has by then. (LoadSucceeded also injects on navigation.)
                    onWebShownChanged: webShown ? obsidianInject.restart() : obsidianInject.stop()
                    // Same guarantee for Dify (the "learn" hub): re-run its transparency
                    // injection every time it's shown — i.e. whenever the panel opens on
                    // the learn tab OR the user switches to it — so the strip + sweep
                    // re-apply (catches Dify's opaque loading screen too).
                    readonly property bool difyShown: webShown && floatingWidget.view === "learn"
                    onDifyShownChanged: difyShown ? difyInject.restart() : difyInject.stop()
                    WebEngineView {
                        id: webObsidian
                        anchors.fill: parent
                        anchors.topMargin: floatingWidget.bottomWebTopInset
                        profile: hubProfile
                        backgroundColor: "transparent"
                        // Let the user select text and use copy/paste in the web
                        // content (clipboard access is off by default in QtWebEngine).
                        settings.javascriptCanAccessClipboard: true
                        settings.javascriptCanPaste: true
                        // Inject the transparency CSS+JS at DocumentCreation — BEFORE the
                        // page's own scripts and its first paint — so the loading screen and
                        // initial frames are never opaque, and the self-persisting observer is
                        // armed before any DOM exists. Runs automatically on every navigation;
                        // the LoadSucceeded re-inject + retry Timer below stay as idempotent
                        // belt-and-braces. Same string the runJavaScript path uses (QS_COLORS
                        // prefix included by the host), so it's fully self-contained.
                        // WebEngineScript is a value type in Qt6 (not creatable as a QML
                        // element), so the collection is populated with a plain JS object.
                        // injectionPoint 2 = DocumentCreation, worldId 0 = MainWorld.
                        userScripts.collection: [{
                            sourceCode: (typeof injectJs !== "undefined") ? injectJs : "",
                            injectionPoint: 2,
                            worldId: 0,
                            runsOnSubFrames: true
                        }]
                        // Stay loaded for the whole session (no about:blank parking) so
                        // there's no reload wait when the panel reopens. With
                        // --disable-gpu-compositing the view renders into the Qt scene
                        // graph, so visible:false / the collapsed (hidden) webFrame
                        // actually tear it down on screen — the old subsurface-keeps-its-
                        // last-frame quirk that forced the about:blank workaround is gone.
                        url: "http://localhost:8765"
                        // Rendered (painting) as soon as the panel starts opening; only
                        // opacity-revealed once the background has grown (webReveal).
                        visible: webFrame.webPaint && floatingWidget.view === "notes"
                        opacity: (webFrame.webReveal && floatingWidget.view === "notes") ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                        onLoadingChanged: function(req) {
                            if (req.status === WebEngineView.LoadSucceeded && typeof injectJs !== "undefined") webObsidian.runJavaScript(injectJs);
                        }
                        // Retry burst, restarted on every open by onWebShownChanged. n
                        // resets each start; stop() (not a running-binding override) so
                        // restart() works cleanly next time the panel opens.
                        Timer { id: obsidianInject; interval: 700; repeat: true; property int n: 0
                            onRunningChanged: if (running) n = 0
                            onTriggered: { if (typeof injectJs !== "undefined") webObsidian.runJavaScript(injectJs); if (++n > 20) stop(); } }
                    }
                    WebEngineView {
                        id: webHermes
                        anchors.fill: parent
                        anchors.topMargin: floatingWidget.hermesWebTopInset
                        profile: hubProfile
                        backgroundColor: "transparent"
                        // Let the user select text and use copy/paste in the web
                        // content (clipboard access is off by default in QtWebEngine).
                        settings.javascriptCanAccessClipboard: true
                        settings.javascriptCanPaste: true
                        // DocumentCreation injection: transparency + zen-mode before first
                        // paint (kills the opaque flash / filler-bg before the SPA hydrates).
                        userScripts.collection: [{
                            sourceCode: (typeof hermesZenJs !== "undefined") ? hermesZenJs : "",
                            injectionPoint: 2,   // DocumentCreation
                            worldId: 0,          // MainWorld
                            runsOnSubFrames: true
                        }]
                        visible: webFrame.webPaint && floatingWidget.view === "hermes"
                        opacity: (webFrame.webReveal && floatingWidget.view === "hermes") ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                        url: floatingWidget.hermesLoaded
                             ? (floatingWidget.hermesPage === "kanban"
                                ? "http://127.0.0.1:9119/kanban"
                                : ("http://127.0.0.1:9119/chat"
                                   + (floatingWidget.hermesResumeId ? "?resume=" + floatingWidget.hermesResumeId : "")))
                             : ""
                        onLoadingChanged: function(req) {
                            if (req.status === WebEngineView.LoadSucceeded) {
                                floatingWidget.hermesLoadFailed = false;
                                hermesRetryDelay.stop();
                                if (typeof hermesZenJs !== "undefined") webHermes.runJavaScript(hermesZenJs);
                            } else if (req.status === WebEngineView.LoadFailed) {
                                // Server still starting up — retry shortly (single-shot,
                                // re-armed here on each failure, capped). No thrash on
                                // success, since Succeeded stops the timer above.
                                floatingWidget.hermesLoadFailed = true;
                                if (hermesRetryDelay.tries < 15) hermesRetryDelay.restart();
                            }
                        }
                        // Re-apply for late React hydration (the JS self-persists after).
                        Timer { running: webFrame.webShown && floatingWidget.view === "hermes"; interval: 800; repeat: true; property int n: 0
                            onRunningChanged: if (running) n = 0
                            onTriggered: { if (typeof hermesZenJs !== "undefined") webHermes.runJavaScript(hermesZenJs); if (++n > 12) running = false; } }
                    }
                    // Single-shot reload, armed by webHermes.onLoadingChanged ONLY on a
                    // genuine LoadFailed (server not yet listening). Reloads once 1.2s
                    // later; if that also fails it re-arms, up to `tries` times. A
                    // successful load stops it. Replaces the old blind 8×-reload burst
                    // that thrashed a healthy, preloaded chat on every open.
                    Timer {
                        id: hermesRetryDelay
                        interval: 1200; repeat: false; property int tries: 0
                        onTriggered: { tries++; webHermes.reload(); }
                    }
                    WebEngineView {
                        id: webDify
                        anchors.fill: parent
                        anchors.topMargin: floatingWidget.bottomWebTopInset
                        profile: hubProfile
                        backgroundColor: "transparent"
                        // Let the user select text and use copy/paste in the web
                        // content (clipboard access is off by default in QtWebEngine).
                        settings.javascriptCanAccessClipboard: true
                        settings.javascriptCanPaste: true
                        // DocumentCreation injection: transparency before first paint so
                        // Dify's opaque loading screen never shows through.
                        userScripts.collection: [{
                            sourceCode: (typeof difyJs !== "undefined") ? difyJs : "",
                            injectionPoint: 2,   // DocumentCreation
                            worldId: 0,          // MainWorld
                            runsOnSubFrames: true
                        }]
                        visible: webFrame.webPaint && floatingWidget.view === "learn"
                        opacity: (webFrame.webReveal && floatingWidget.view === "learn") ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                        url: floatingWidget.learnLoaded ? "http://localhost:8090" : ""
                        onLoadingChanged: function(req) {
                            if (req.status === WebEngineView.LoadSucceeded && typeof difyJs !== "undefined") webDify.runJavaScript(difyJs);
                        }
                        // Retry burst, restarted on every open/switch-to-learn by
                        // onDifyShownChanged (no running-binding to break). Resets its
                        // counter each start; stop() so restart() works cleanly next time.
                        Timer { id: difyInject; interval: 800; repeat: true; property int n: 0
                            onRunningChanged: if (running) n = 0
                            onTriggered: { if (typeof difyJs !== "undefined") webDify.runJavaScript(difyJs); if (++n > 12) stop(); } }
                    }
                    Timer {
                        id: learnRetry
                        interval: 1500; repeat: true; property int n: 0
                        onRunningChanged: if (running) n = 0
                        onTriggered: { if (floatingWidget.view === "learn") webDify.reload(); if (++n > 12) running = false; }
                    }

                    // ── HAMBURGER: opens the sessions panel ────────────────────
                    // Top-left of the chat popup (inset past the selector strip on
                    // that edge). Three-line menu glyph; hidden while the panel is
                    // open (the panel carries its own close button). z:6 keeps it
                    // above the web view and the panel.
                    Rectangle {
                        id: sessionsHamburger
                        z: 6
                        // Flush in the top-left corner, on the margin. The selector
                        // strip is vertically centered on the left edge, so the
                        // corner is clear — no inset needed.
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.topMargin: floatingWidget.s(10)
                        anchors.leftMargin: floatingWidget.s(10)
                        width: floatingWidget.s(34)
                        height: floatingWidget.s(34)
                        radius: floatingWidget.s(9)
                        readonly property bool shown: floatingWidget.view === "hermes"
                            && webFrame.webShown && !floatingWidget.sessionsOpen
                            && floatingWidget.hermesPage === "chat"
                        visible: opacity > 0.01
                        opacity: shown ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
                        color: hbMouse.pressed ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.5)
                             : (hbMouse.containsMouse ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.3)
                                                      : Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.85))
                        border.width: floatingWidget.s(1)
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.14)
                        Behavior on color { ColorAnimation { duration: 180 } }
                        // Three lines drawn as rectangles (crisp at any scale).
                        Column {
                            anchors.centerIn: parent
                            spacing: floatingWidget.s(3)
                            Repeater {
                                model: 3
                                Rectangle {
                                    width: floatingWidget.s(16); height: floatingWidget.s(2)
                                    radius: height / 2
                                    color: hbMouse.containsMouse ? mocha.mauve : mocha.text
                                    Behavior on color { ColorAnimation { duration: 180 } }
                                }
                            }
                        }
                        MouseArea {
                            id: hbMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: hideTimer.stop()
                            onExited: floatingWidget.kickTimer()
                            onClicked: floatingWidget.toggleSessions()
                        }
                    }

                    // ── NEW CHAT: start a fresh conversation (visible top-level;
                    // the sessions/history panel also has one, but this saves a
                    // click). Sits right of the hamburger, same style. ──────────
                    Rectangle {
                        id: newChatBtn
                        z: 6
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.topMargin: floatingWidget.s(10)
                        anchors.leftMargin: floatingWidget.s(10) + floatingWidget.s(34) + floatingWidget.s(8)
                        width: floatingWidget.s(34)
                        height: floatingWidget.s(34)
                        radius: floatingWidget.s(9)
                        readonly property bool shown: floatingWidget.view === "hermes"
                            && webFrame.webShown && !floatingWidget.sessionsOpen
                            && floatingWidget.hermesPage === "chat"
                        visible: opacity > 0.01
                        opacity: shown ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
                        color: ncMouse.pressed ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.5)
                             : (ncMouse.containsMouse ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.3)
                                                      : Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.85))
                        border.width: floatingWidget.s(1)
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.14)
                        Behavior on color { ColorAnimation { duration: 180 } }
                        // Plus glyph drawn from two bars (crisp at any scale).
                        Item {
                            anchors.centerIn: parent
                            width: floatingWidget.s(16); height: floatingWidget.s(16)
                            Rectangle { anchors.centerIn: parent; width: floatingWidget.s(15); height: floatingWidget.s(3)
                                radius: height / 2; color: ncMouse.containsMouse ? mocha.mauve : mocha.text
                                Behavior on color { ColorAnimation { duration: 180 } } }
                            Rectangle { anchors.centerIn: parent; width: floatingWidget.s(3); height: floatingWidget.s(15)
                                radius: width / 2; color: ncMouse.containsMouse ? mocha.mauve : mocha.text
                                Behavior on color { ColorAnimation { duration: 180 } } }
                        }
                        MouseArea {
                            id: ncMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: hideTimer.stop()
                            onExited: floatingWidget.kickTimer()
                            // Fresh conversation: if already on the bare /chat URL a
                            // resume-clear is a no-op, so reload to reset; otherwise
                            // clearing the resume id rebinds the URL to /chat.
                            onClicked: {
                                floatingWidget.sessionsOpen = false;
                                if (floatingWidget.hermesResumeId === "") webHermes.reload();
                                else floatingWidget.hermesResumeId = "";
                                floatingWidget.kickTimer();
                            }
                        }
                    }

                    // ── KANBAN TOGGLE: swaps the Hermes web view chat ⇄ kanban ──
                    // Top-right of the chat popup, on the margin (mirrors the
                    // top-left sessions hamburger). On the chat page it shows a
                    // board glyph (three columns); on the kanban page it becomes an
                    // X to go back. Both are drawn from rectangles so they render
                    // crisply at any scale, independent of the icon font.
                    Rectangle {
                        id: kanbanToggle
                        z: 6
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: floatingWidget.s(10)
                        anchors.rightMargin: floatingWidget.s(10)
                        width: floatingWidget.s(34)
                        height: floatingWidget.s(34)
                        radius: floatingWidget.s(9)
                        readonly property bool onKanban: floatingWidget.hermesPage === "kanban"
                        readonly property bool shown: floatingWidget.view === "hermes" && webFrame.webShown
                        visible: opacity > 0.01
                        opacity: shown ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
                        color: kbMouse.pressed ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.5)
                             : (kbMouse.containsMouse ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.3)
                                                      : Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.85))
                        border.width: floatingWidget.s(1)
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.14)
                        Behavior on color { ColorAnimation { duration: 180 } }

                        Item {
                            anchors.centerIn: parent
                            width: floatingWidget.s(16); height: floatingWidget.s(16)
                            // Board columns — shown on the chat page.
                            Row {
                                anchors.centerIn: parent
                                spacing: floatingWidget.s(2)
                                opacity: kanbanToggle.onKanban ? 0 : 1
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                                Repeater {
                                    model: 3
                                    Rectangle {
                                        width: floatingWidget.s(3); height: floatingWidget.s(14)
                                        radius: floatingWidget.s(1)
                                        color: kbMouse.containsMouse ? mocha.mauve : mocha.text
                                        Behavior on color { ColorAnimation { duration: 180 } }
                                    }
                                }
                            }
                            // X — shown on the kanban page (click to return to chat).
                            Item {
                                anchors.fill: parent
                                opacity: kanbanToggle.onKanban ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: floatingWidget.s(18); height: floatingWidget.s(2)
                                    radius: height / 2; rotation: 45
                                    color: kbMouse.containsMouse ? mocha.mauve : mocha.text
                                    Behavior on color { ColorAnimation { duration: 180 } }
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: floatingWidget.s(18); height: floatingWidget.s(2)
                                    radius: height / 2; rotation: -45
                                    color: kbMouse.containsMouse ? mocha.mauve : mocha.text
                                    Behavior on color { ColorAnimation { duration: 180 } }
                                }
                            }
                        }
                        MouseArea {
                            id: kbMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: hideTimer.stop()
                            onExited: floatingWidget.kickTimer()
                            onClicked: floatingWidget.toggleKanban()
                        }
                    }

                    // ── HERMES SESSIONS PANEL ──────────────────────────────────
                    // Overlays the LEFT of the chat, above the web view (z:5 beats
                    // the WebEngineViews now that --disable-gpu-compositing renders
                    // them into the scene graph). Slides + fades in like the
                    // selector strip. Inset from the left so it never hides behind
                    // the selector strip on that edge.
                    Item {
                        id: sessionsPanel
                        z: 5
                        readonly property int leftInset: floatingWidget.activeEdge === "left"
                            ? floatingWidget.sidebarW + floatingWidget.s(6) : floatingWidget.s(6)
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        x: leftInset
                        width: Math.min(floatingWidget.s(320), parent.width - leftInset - floatingWidget.s(20))
                        readonly property bool shown: floatingWidget.view === "hermes"
                            && floatingWidget.sessionsOpen && webFrame.webShown
                        visible: opacity > 0.01
                        opacity: shown ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
                        // Slide tied to the fade (opacity animates via the Behavior above),
                        // so the panel eases in from the left as it appears.
                        transform: Translate { x: (1 - sessionsPanel.opacity) * -floatingWidget.s(24) }

                        // Card background — matugen base, blurred edge, like other panels.
                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: floatingWidget.s(10)
                            anchors.bottomMargin: floatingWidget.s(10)
                            radius: floatingWidget.s(14)
                            color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.92)
                            border.width: floatingWidget.s(1)
                            border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.12)

                            // Keep hover here from collapsing the panel.
                            MouseArea { anchors.fill: parent; hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                                onEntered: hideTimer.stop()
                                onExited: floatingWidget.kickTimer() }

                            Column {
                                anchors.fill: parent
                                anchors.margins: floatingWidget.s(12)
                                spacing: floatingWidget.s(8)

                                // Header row: title + refresh + close
                                Item {
                                    width: parent.width; height: floatingWidget.s(26)
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Sessions"
                                        color: mocha.text
                                        font.family: "Iosevka Nerd Font"
                                        font.pixelSize: floatingWidget.s(15)
                                        font.bold: true
                                    }
                                    Row {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: floatingWidget.s(6)
                                        Text {
                                            text: "󰑐"   // refresh
                                            color: refreshMa.containsMouse ? mocha.mauve : mocha.subtext0
                                            font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(15)
                                            MouseArea { id: refreshMa; anchors.fill: parent; anchors.margins: -floatingWidget.s(4)
                                                hoverEnabled: true; onClicked: floatingWidget.loadSessions() }
                                        }
                                        Text {
                                            text: "󰅖"   // close
                                            color: closeMa.containsMouse ? mocha.red : mocha.subtext0
                                            font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(15)
                                            MouseArea { id: closeMa; anchors.fill: parent; anchors.margins: -floatingWidget.s(4)
                                                hoverEnabled: true; onClicked: floatingWidget.sessionsOpen = false }
                                        }
                                    }
                                }

                                // New chat row
                                Rectangle {
                                    width: parent.width; height: floatingWidget.s(34)
                                    radius: floatingWidget.s(8)
                                    color: newMa.containsMouse ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.22)
                                                               : Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.5)
                                    border.width: floatingWidget.s(1)
                                    border.color: Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.4)
                                    Row {
                                        anchors.left: parent.left; anchors.leftMargin: floatingWidget.s(10)
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: floatingWidget.s(8)
                                        Text { text: "󰝥"; color: mocha.mauve; font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(14)
                                               anchors.verticalCenter: parent.verticalCenter }
                                        Text { text: "New chat"; color: mocha.text; font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(13)
                                               anchors.verticalCenter: parent.verticalCenter }
                                    }
                                    MouseArea { id: newMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: floatingWidget.openSession("") }
                                }

                                // Session list (fills the rest)
                                ListView {
                                    id: sessionsList
                                    width: parent.width
                                    height: parent.height - floatingWidget.s(26) - floatingWidget.s(34) - floatingWidget.s(16)
                                    clip: true
                                    spacing: floatingWidget.s(4)
                                    model: sessionsModel
                                    boundsBehavior: Flickable.StopAtBounds

                                    delegate: Rectangle {
                                        required property string sid
                                        required property string preview
                                        required property string sub
                                        width: sessionsList.width
                                        height: floatingWidget.s(46)
                                        radius: floatingWidget.s(8)
                                        readonly property bool isCurrent: sid === floatingWidget.hermesResumeId
                                        color: rowMa.containsMouse ? Qt.rgba(mocha.surface2.r, mocha.surface2.g, mocha.surface2.b, 0.7)
                                             : (isCurrent ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.18)
                                                          : Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.4))
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Column {
                                            anchors.fill: parent
                                            anchors.leftMargin: floatingWidget.s(10)
                                            anchors.rightMargin: floatingWidget.s(8)
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: floatingWidget.s(2)
                                            Item { width: 1; height: floatingWidget.s(6) }
                                            Text {
                                                width: parent.width
                                                text: preview
                                                color: mocha.text
                                                font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(12)
                                                elide: Text.ElideRight; maximumLineCount: 1
                                            }
                                            Text {
                                                text: sub
                                                color: mocha.subtext0
                                                font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(10)
                                            }
                                        }
                                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true
                                            onClicked: floatingWidget.openSession(sid) }
                                    }

                                    // Empty / loading state
                                    Text {
                                        anchors.centerIn: parent
                                        visible: sessionsModel.count === 0
                                        text: floatingWidget.sessionsLoading ? "Loading…" : "No sessions"
                                        color: mocha.subtext0
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: floatingWidget.s(12)
                                    }
                                }
                            }
                        }
                    }
                }

                MouseArea {
                    id: gridMouseArea
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                    onEntered: hideTimer.stop()
                    onExited: { if (!sidebarDragArea.containsMouse) floatingWidget.kickTimer(); }
                    onWheel: wheel => { wheel.accepted = false; }
                }
            }

            // =========================================================
            // --- BOTTOM-DOCK RESIZE BAR (drag to change popup height)
            // =========================================================
            // Sits ABOVE the selector strip at the top of the bottom column.
            // Dragging up grows the popup, down shrinks it (anchored at the
            // screen bottom, so the top edge is the resize edge). Bottom dock
            // only; z above the selector (10) so it's always grabbable.
            Item {
                id: bottomResizeHandle
                z: 11
                visible: floatingWidget.activeEdge === "bottom" && floatingWidget.expandProgress > 0.5
                width: Math.min(floatingWidget.panelW * 0.6, floatingWidget.s(160))
                height: floatingWidget.bottomResizeBarH
                x: (floatingWidget.panelW - width) / 2
                y: floatingWidget.s(2)

                Rectangle {
                    id: bottomResizeGrip
                    anchors.centerIn: parent
                    width: parent.width
                    height: floatingWidget.s(5)
                    radius: height / 2
                    // subtext0 at rest (clearly visible, matching the expand arrow),
                    // mauve on hover/drag for feedback.
                    color: (bottomResizeMouse.pressed || bottomResizeMouse.containsMouse)
                        ? mocha.mauve
                        : mocha.subtext0
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                MouseArea {
                    id: bottomResizeMouse
                    anchors.fill: parent
                    anchors.margins: -floatingWidget.s(7)   // fat grab target
                    hoverEnabled: true
                    cursorShape: Qt.SizeVerCursor
                    property real startGY: 0
                    property real baseLen: 0
                    onEntered: hideTimer.stop()
                    onExited: { if (!pressed) floatingWidget.kickTimer(); }
                    onPressed: mouse => {
                        var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                        startGY = gp.y;
                        baseLen = floatingWidget.expandedExtraLength;
                        floatingWidget.resizing = true;
                        floatingWidget.useGraceTimer = true;
                        hideTimer.stop();
                    }
                    onPositionChanged: mouse => {
                        if (!pressed) return;
                        var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                        // Drag UP (y decreases) → taller popup.
                        floatingWidget.bottomExtraOverride = baseLen + (startGY - gp.y);
                        floatingWidget.updateSizes();
                    }
                    onReleased: {
                        floatingWidget.resizing = false;
                        if (!containsMouse) floatingWidget.kickTimer();
                    }
                }
            }

            // =========================================================
            // --- SELECTOR STRIP (control area + pills)
            // =========================================================
            Item {
                id: staticContentWrapper
                // Render explicitly ABOVE the web hub so the selector strip always
                // overlays the (now full-bleed) web view. Declaration order already
                // puts it last, but an explicit z makes the intent unambiguous and
                // survives any future reorder.
                z: 10
                width: floatingWidget.sidebarW
                height: floatingWidget.baseSidebarH
                rotation: floatingWidget.activeEdge === "bottom" ? -90 : 0
                transformOrigin: Item.Center
                x: {
                    if (floatingWidget.activeEdge === "left")  return floatingWidget.currentExtraWidth;
                    if (floatingWidget.activeEdge === "right") return 0;
                    return (floatingWidget.panelW / 2) - (floatingWidget.sidebarW / 2);
                }
                y: {
                    // Bottom dock: strip pinned to the panel TOP; when expanded, drop
                    // it by the resize-bar height so the drag bar sits above it. Scaled
                    // by expandProgress so the collapsed nub stays flush at the edge.
                    if (floatingWidget.activeEdge === "bottom") return (floatingWidget.sidebarW / 2) - (floatingWidget.baseSidebarH / 2) + floatingWidget.bottomResizeBarH * floatingWidget.expandProgress;
                    return (floatingWidget.panelH / 2) - (floatingWidget.baseSidebarH / 2);
                }

                Item {
                    anchors.fill: parent
                    anchors.margins: floatingWidget.s(8)

                    // ── CONTROL AREA (expand + pin) ──
                    Item {
                        id: controlArea
                        width: parent.width
                        height: floatingWidget.controlAreaHeight
                        x: 0
                        y: (floatingWidget.activeEdge === "left" || floatingWidget.activeEdge === "bottom") ? 0 : floatingWidget.getTargetY(floatingWidget.tabCount, floatingWidget.activeIndex)
                        Behavior on y { enabled: !floatingWidget.disableAnim; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }

                        // EXPAND BUTTON (the arrow-glyph morph)
                        Item {
                            id: expandButton
                            width: floatingWidget.buttonSize
                            height: floatingWidget.buttonSize
                            x: (parent.width - width) / 2
                            y: (floatingWidget.activeEdge === "left" || floatingWidget.activeEdge === "bottom") ? floatingWidget.s(6) : parent.height - height - floatingWidget.s(6)
                            rotation: floatingWidget.isExpanded ? 180 : 0
                            Behavior on rotation { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }

                            Item {
                                anchors.fill: parent
                                // Idle uses subtext0 (clearly visible at rest) rather than
                                // the old near-invisible base+text@0.3 tint, so the arrow
                                // reads against the strip without needing a hover.
                                property color iconColor: floatingWidget.isExpanded ? mocha.mauve :
                                    (expandMouse.pressed ? Qt.darker(mocha.mauve, 1.2) :
                                    (expandMouse.containsMouse ? mocha.mauve : mocha.subtext0))
                                property real pivotX: parent.width / 2 - floatingWidget.s(4)
                                Rectangle {
                                    width: floatingWidget.s(5); height: floatingWidget.s(5); radius: width / 2
                                    color: parent.iconColor
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: parent.pivotX - (width / 2)
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                Rectangle {
                                    x: parent.pivotX; anchors.verticalCenter: parent.verticalCenter
                                    width: floatingWidget.s(13); height: floatingWidget.s(4.5); radius: height / 2
                                    transformOrigin: Item.Left; rotation: 42; color: parent.iconColor
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                Rectangle {
                                    x: parent.pivotX; anchors.verticalCenter: parent.verticalCenter
                                    width: floatingWidget.s(13); height: floatingWidget.s(4.5); radius: height / 2
                                    transformOrigin: Item.Left; rotation: -42; color: parent.iconColor
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                            }

                            MouseArea {
                                id: expandMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                property real startGlobalX: 0
                                property real startGlobalY: 0
                                property bool isDragging: false
                                onEntered: hideTimer.stop()
                                onExited: floatingWidget.kickTimer()
                                onPressed: mouse => { var gp = mapToItem(mainHitArea, mouse.x, mouse.y); startGlobalX = gp.x; startGlobalY = gp.y; isDragging = false; }
                                onPositionChanged: mouse => {
                                    if (!pressed) return;
                                    var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                                    if (Math.abs(gp.x - startGlobalX) > 12 || Math.abs(gp.y - startGlobalY) > 12) {
                                        isDragging = true;
                                        floatingWidget.evaluateDrag(startGlobalX, startGlobalY, gp.x, gp.y);
                                    }
                                }
                                onClicked: { if (!isDragging) { floatingWidget.isExpanded = !floatingWidget.isExpanded; floatingWidget.kickTimer(); } }
                            }
                        }

                        // PIN BUTTON
                        Rectangle {
                            id: pinButton
                            width: floatingWidget.buttonSize
                            height: floatingWidget.buttonSize
                            radius: width / 2
                            x: (parent.width - width) / 2
                            y: (floatingWidget.activeEdge === "left" || floatingWidget.activeEdge === "bottom") ? expandButton.y + expandButton.height + floatingWidget.s(8) : expandButton.y - height - floatingWidget.s(8)
                            // Off → hollow (transparent centre, bright ring); on → solid
                            // mauve disc with no ring competing with the fill. A faint mauve
                            // wash on hover hints it's clickable while still off.
                            color: floatingWidget.isPinned ? mocha.mauve :
                                (pinMouse.pressed ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.4) :
                                (pinMouse.containsMouse ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.22) : "transparent"))
                            border.width: floatingWidget.isPinned ? 0 : floatingWidget.s(2)
                            // Outline uses the matugen accent so it themes with the palette
                            // (mauve ring when off → mauve fill when on).
                            border.color: mocha.mauve
                            Behavior on color { ColorAnimation { duration: 200 } }
                            Behavior on border.color { ColorAnimation { duration: 200 } }
                            MouseArea {
                                id: pinMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                property real startGlobalX: 0
                                property real startGlobalY: 0
                                property bool isDragging: false
                                onEntered: hideTimer.stop()
                                onExited: floatingWidget.kickTimer()
                                onPressed: mouse => { var gp = mapToItem(mainHitArea, mouse.x, mouse.y); startGlobalX = gp.x; startGlobalY = gp.y; isDragging = false; }
                                onPositionChanged: mouse => {
                                    if (!pressed) return;
                                    var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                                    if (Math.abs(gp.x - startGlobalX) > 5 || Math.abs(gp.y - startGlobalY) > 5) isDragging = true;
                                    floatingWidget.evaluateDrag(startGlobalX, startGlobalY, gp.x, gp.y);
                                }
                                onClicked: { if (!isDragging) floatingWidget.isPinned = !floatingWidget.isPinned; }
                            }
                        }
                    }

                    // ── Sliding active-pill highlight ──
                    Rectangle {
                        id: activeHighlight
                        x: 0; width: parent.width; z: 0
                        radius: floatingWidget.s(7)
                        color: mocha.mauve
                        property int prevIdx: 0
                        property int curIdx: floatingWidget.activeIndex
                        onCurIdxChanged: {
                            if (curIdx > prevIdx) { bottomAnim.duration = 200; topAnim.duration = 350; }
                            else if (curIdx < prevIdx) { topAnim.duration = 200; bottomAnim.duration = 350; }
                            prevIdx = curIdx;
                        }
                        property real targetTop: floatingWidget.barOffsetY + floatingWidget.getTargetY(curIdx, curIdx)
                        property real targetBottom: targetTop + floatingWidget.h_ac
                        property real actualTop: targetTop
                        property real actualBottom: targetBottom
                        Behavior on actualTop { NumberAnimation { id: topAnim; duration: 250; easing.type: Easing.OutExpo } }
                        Behavior on actualBottom { NumberAnimation { id: bottomAnim; duration: 250; easing.type: Easing.OutExpo } }
                        y: actualTop
                        height: actualBottom - actualTop
                    }

                    // ── Pills (Obsidian / Hermes / Dify glyphs) ──
                    Repeater {
                        model: [ { glyph: "󰠮", idx: 0 },     // Obsidian
                                 { glyph: "󰚩", idx: 1 },     // Hermes
                                 { glyph: "󰷄", idx: 2 } ]    // Dify
                        delegate: Rectangle {
                            id: barPill
                            required property int index
                            required property var modelData
                            property bool isActive: floatingWidget.activeIndex === index
                            property bool isHovered: barMouse.containsMouse
                            property bool isPressed: barMouse.pressed
                            x: 0; width: parent.width; radius: floatingWidget.s(7); z: 1
                            y: floatingWidget.barOffsetY + floatingWidget.getTargetY(index, floatingWidget.activeIndex)
                            Behavior on y { enabled: !floatingWidget.disableAnim; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }
                            height: isActive ? floatingWidget.h_ac : floatingWidget.h_in
                            Behavior on height { enabled: !floatingWidget.disableAnim; NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }
                            // Inactive pills get a solid surface fill (+ outline) instead of the
                            // old text@0.15 wash, so each tab reads as a distinct chip on the
                            // strip — and over the transparent web view when expanded.
                            color: isActive ? "transparent" : (isPressed ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.45) : (isHovered ? Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.3) : Qt.rgba(mocha.surface2.r, mocha.surface2.g, mocha.surface2.b, 0.6)))
                            Behavior on color { ColorAnimation { duration: 250 } }
                            border.width: isActive ? 0 : floatingWidget.s(1)
                            border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.42)
                            scale: isActive ? 1.0 : (isPressed ? 0.95 : (isHovered ? 1.05 : 1.0))
                            Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }

                            Text {
                                anchors.centerIn: parent
                                text: barPill.modelData.glyph
                                font.family: "Iosevka Nerd Font"
                                font.pixelSize: floatingWidget.s(16)
                                // Counter-rotate the glyph on the bottom edge so it stays upright.
                                rotation: floatingWidget.activeEdge === "bottom" ? 90 : 0
                                // Active glyph on the mauve highlight → crust; inactive on the
                                // surface chip → full text (not the dim subtext0).
                                color: barPill.isActive ? mocha.crust : mocha.text
                            }

                            MouseArea {
                                id: barMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                // Left = select/toggle the in-panel view; middle = pop this
                                // hub's full webui open in the system browser.
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                property real startGlobalX: 0
                                property real startGlobalY: 0
                                property bool isDragging: false
                                onEntered: { floatingWidget.hoveredBars++; hideTimer.stop(); }
                                onExited: { floatingWidget.hoveredBars = Math.max(0, floatingWidget.hoveredBars - 1); floatingWidget.kickTimer(); }
                                onPressed: mouse => { var gp = mapToItem(mainHitArea, mouse.x, mouse.y); startGlobalX = gp.x; startGlobalY = gp.y; isDragging = false; }
                                onPositionChanged: mouse => {
                                    if (!pressed) return;
                                    var gp = mapToItem(mainHitArea, mouse.x, mouse.y);
                                    if (Math.abs(gp.x - startGlobalX) > 12 || Math.abs(gp.y - startGlobalY) > 12) {
                                        isDragging = true;
                                        floatingWidget.evaluateDrag(startGlobalX, startGlobalY, gp.x, gp.y);
                                    }
                                }
                                onClicked: mouse => {
                                    if (isDragging) return;
                                    if (mouse.button === Qt.MiddleButton) {
                                        floatingWidget.openExternal(index);
                                        return;
                                    }
                                    if (!barPill.isActive) floatingWidget.selectView(index);
                                    else floatingWidget.isExpanded = !floatingWidget.isExpanded;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =========================================================
    // --- WEB VIEW SWITCHING (lazy-load Hermes/Dify on first show)
    // =========================================================
    property bool hermesLoaded: false
    property bool learnLoaded: false
    // Hermes chat load state, to reload only on genuine failure (not blindly), and
    // to reconnect once after a cold-model warm. See webHermes.onLoadingChanged +
    // hermesRetryDelay + warmHermesModel below.
    property bool hermesLoadFailed: false
    property bool hermesWarming: false
    // The full webui URL behind each pill, by index (Obsidian / Hermes / Dify).
    readonly property var viewUrls: ["http://localhost:8765",
                                     "http://127.0.0.1:9119/chat",
                                     "http://localhost:8090"]
    // Kick the on-demand llama.cpp model the moment Hermes is opened, so it's warm
    // by the time the chat UI probes connectivity / the user sends a message.
    //
    // The backend (llama-server :11435) is fronted by the socket-activated
    // qwable-proxy on :11434 that auto-unloads after 5 min idle (frees VRAM). A cold
    // load takes ~40s, during which short-timeout clients — notably Hermes'
    // fetch_models() connectivity probe (8s) — time out and report "no connection".
    // This fire-and-forget request both TRIGGERS the socket-activated load early and
    // counts as activity (resetting the idle-unload timer); the generous -m gives the
    // model time to finish loading. It returns fast/harmlessly if already warm. We do
    // it on every Hermes open (not just first), since the model can unload between visits.
    function warmHermesModel() {
        // sh.fetch (not sh.run) so we get a completion signal: the command prints
        // how many seconds the warm took. A COLD load (model was unloaded) takes
        // tens of seconds, during which the chat's ~8s connectivity probe times out
        // and shows "no connection" — so onFetched reloads the view ONCE when the
        // warm was slow, reconnecting now the model is up. Warm hits return in <1s
        // and are left untouched (no reload thrash). Guarded so overlapping opens
        // don't stack warms.
        if (hermesWarming) return;
        hermesWarming = true;
        sh.fetch("hermeswarm", "s=$SECONDS; curl -sf -m 180 http://127.0.0.1:11434/v1/models >/dev/null 2>&1; echo $((SECONDS-s))");
    }
    function ensureHermesServer() {
        // Make sure the Hermes dashboard web server is serving on :9119.
        if (hermesLoaded) return;
        sh.run('export PATH="$HOME/.local/bin:$HOME/.hermes/venv/bin:$PATH"; '
             + "ss -tln 2>/dev/null | grep -q ':9119 ' || "
             + "(setsid hermes dashboard --no-open --port 9119 --skip-build >/dev/null 2>&1 &)");
        hermesLoaded = true;
    }
    // Middle-click a pill → open that hub's full webui in the system browser
    // (a real window, separate from the embedded panel view).
    function openExternal(idx) {
        var url = floatingWidget.viewUrls[idx] || "";
        if (url === "") return;
        if (idx === 1) { ensureHermesServer(); warmHermesModel(); }
        sh.run('xdg-open "' + url + '"');
        kickTimer();
    }
    function selectView(idx) {
        floatingWidget.activeIndex = idx;
        if (idx === 1) {
            ensureHermesServer();
            warmHermesModel();   // pre-load the llama.cpp model so the chat connects
            // The chat is preloaded at startup; only reload if that load actually
            // failed (server was still coming up), instead of a blind reload burst
            // that would tear down and respawn a healthy PTY session.
            if (hermesLoadFailed) { hermesRetryDelay.tries = 0; webHermes.reload(); }
        } else if (idx === 2 && !learnLoaded) {
            learnLoaded = true; learnRetry.restart();
        } else if (idx !== 1) {
            floatingWidget.sessionsOpen = false;   // sessions panel is Hermes-only
        }
        kickTimer();
    }

    // =========================================================
    // --- HERMES SESSIONS PANEL (native QML, overlays the chat)
    // =========================================================
    // A button in the selector opens this panel over the Hermes chat (like the
    // selector strip itself overlays the web view). The list is fetched from the
    // Hermes API on :8642 — the bearer token is read from the keyring INSIDE the
    // shell command (sh.fetch), so it never lives in QML. Clicking a row loads
    // that session via the dashboard's ?resume=<id> URL.
    property bool sessionsOpen: false
    property string hermesResumeId: ""   // "" = fresh /chat (new conversation)
    property bool sessionsLoading: false
    ListModel { id: sessionsModel }

    // Which Hermes page the embedded web view shows: "chat" (default) or
    // "kanban". The top-right toggle button swaps between them (webHermes.url
    // rebinds → navigates). Kanban is board-only, so opening it closes the
    // chat-scoped sessions panel.
    property string hermesPage: "chat"
    function toggleKanban() {
        floatingWidget.hermesPage = (floatingWidget.hermesPage === "kanban") ? "chat" : "kanban";
        if (floatingWidget.hermesPage === "kanban") floatingWidget.sessionsOpen = false;
        floatingWidget.kickTimer();
    }

    function loadSessions() {
        floatingWidget.sessionsLoading = true;
        // Token pulled from the keyring in-command; -m 3 keeps it from hanging.
        sh.fetch("sessions",
            'curl -s -m 3 -H "Authorization: Bearer ' +
            '$(secret-tool lookup service qs-hypr key hermes_token 2>/dev/null)" ' +
            '"http://localhost:8642/api/sessions?limit=50"');
    }
    function relTime(ts) {
        if (!ts) return "";
        var d = (Date.now() / 1000) - ts;
        if (d < 60) return "just now";
        if (d < 3600) return Math.floor(d / 60) + "m ago";
        if (d < 86400) return Math.floor(d / 3600) + "h ago";
        if (d < 604800) return Math.floor(d / 86400) + "d ago";
        return Math.floor(d / 604800) + "w ago";
    }
    Connections {
        target: sh
        function onFetched(tag, out) {
            if (tag === "hermeswarm") {
                floatingWidget.hermesWarming = false;
                // Cold load (model was unloaded): the chat's ~8s connectivity probe
                // already gave up, so reload once now the model is up to reconnect.
                // Warm hits (<1s) are left untouched — no thrash.
                if (parseInt(out) > 8 && floatingWidget.view === "hermes") webHermes.reload();
                return;
            }
            if (tag !== "sessions") return;
            floatingWidget.sessionsLoading = false;
            sessionsModel.clear();
            try {
                var d = JSON.parse(out);
                var arr = (d && d.data) ? d.data : (Array.isArray(d) ? d : []);
                for (var i = 0; i < arr.length; i++) {
                    var s = arr[i];
                    var id = s.id || s.session_id || "";
                    if (!id) continue;
                    var prev = (s.preview || s.name || id).toString();
                    if (prev.length > 80) prev = prev.slice(0, 80) + "…";
                    sessionsModel.append({
                        sid: id,
                        preview: prev,
                        sub: floatingWidget.relTime(s.last_active || s.updated_at || 0)
                             + (s.message_count ? "  ·  " + s.message_count + " msg" : "")
                    });
                }
            } catch (e) { /* leave the list empty; the panel shows "no sessions" */ }
        }
    }
    function openSession(id) {
        floatingWidget.hermesResumeId = id;     // rebinds webHermes.url → navigates
        floatingWidget.sessionsOpen = false;
        floatingWidget.kickTimer();
    }
    function toggleSessions() {
        floatingWidget.sessionsOpen = !floatingWidget.sessionsOpen;
        if (floatingWidget.sessionsOpen) loadSessions();
        floatingWidget.kickTimer();
    }
}
