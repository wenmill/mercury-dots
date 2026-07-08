import QtQuick
import QtQuick.Window
import QtWebEngine

// Frameless overlay window for the Matrix panel: an app-launcher-style matugen
// background with Element Web (transparent) rendered on top. Everything lives in
// ONE toplevel window, so the background is guaranteed to sit behind the web view
// (a separate Quickshell layer panel can't be reliably stacked under a toplevel).
//
// Transparency recipe:
//   Window.color: "transparent"                -> rounded corners show desktop
//   WebEngineView.backgroundColor: transparent -> web view paints no base layer
//   injected CSS                               -> Element's own opaque layers off
// so the matugen background below shows through Element.
Window {
    id: win
    visible: true
    width: 647    // app launcher footprint on this monitor (Hyprland rule enforces it)
    height: 577
    // Fixed min==max size -> the xdg-toplevel is non-resizable (Hyprland won't resize it).
    minimumWidth: 647;  maximumWidth: 647
    minimumHeight: 577; maximumHeight: 577
    color: "transparent"
    flags: Qt.FramelessWindowHint
    title: "ElementMatrixOverlay"

    // matugen palette passed from Python (qs_colors.json); fall back to Catppuccin.
    readonly property var c: (typeof qsColors !== "undefined" && qsColors) ? qsColors : ({})
    function col(k, fb) { return c[k] ? c[k] : fb; }

    // ── Force-repaint on re-show ────────────────────────────────────────────────
    // When the overlay is "closed" it's parked on a hidden workspace, which
    // UNMAPS its surface; Chromium then keeps the last (black) GPU buffer. On the
    // next open the surface is remapped but nothing repaints it, so it shows
    // black until something invalidates it. Nudge the web view's size by 1px
    // (margins 2 -> 3 -> 2) whenever the window is shown/focused: the resize makes
    // QtWebEngine allocate a fresh buffer and repaint, clearing the black.
    property int repaintKick: 0
    // Raise the cover just before the window is parked/unmapped so the surface's
    // LAST committed frame is matugen, never black. Called by the Python host
    // right before it dispatches the park — NOT on every blur: raising it on any
    // focus loss made transient focus blips flash the dark cover over the open
    // overlay ("random black flicker").
    function raiseCover() { coverFade.stop(); reshowCover.opacity = 1; }
    // On re-show: keep the cover up, force a fresh repaint underneath it, then
    // fade it out — so the only thing ever visible on re-open is the matugen base.
    function revealAfterRepaint() {
        coverFade.stop();
        reshowCover.opacity = 1;     // ensure still covered
        win.repaintKick = 1;         // 1px resize -> QtWebEngine repaints underneath
        repaintResetTimer.restart();
    }
    onActiveChanged: {
        if (!active) return;       // cover is raised by the host pre-park, not here
        win.pointerSeen = false;   // re-arm the travel guard for this show cycle
        if (win.pageDead || win.pageParked
                || web.lifecycleState === WebEngineView.LifecycleState.Discarded || !web.visible)
            revive();
        else
            revealAfterRepaint();
    }
    Timer {
        id: repaintResetTimer
        interval: 55; repeat: false   // short: the renderer is warm on this path
        onTriggered: { win.repaintKick = 0; coverFade.start(); }   // fade cover -> reveal Element
    }

    // ── Renderer lifecycle: discard when parked, revive on show ──────────────
    // The overlay idles 24/7 parked on special:matrix with Element's renderer
    // resident (~175MB). After discardMs unfocused, drop the renderer via
    // lifecycleState Discarded (a view must be non-visible to be discarded; the
    // parked surface is unmapped anyway so nothing on screen changes). Re-showing
    // revives behind the reshow cover, which on this path stays up until the page
    // has actually reloaded. The same revive path self-heals renderer crashes,
    // which previously left a dead page until the app was restarted.
    property bool pageDead: false
    property bool reviving: false
    property bool pageParked: false   // parked at about:blank (renderer released)

    // Blur-close travel guard: with focus-follows-mouse the overlay blurs while
    // the pointer travels from the topbar button to it, which used to fire the
    // 160ms close-on-blur before the pointer arrived. The Python host only
    // fast-parks once the pointer has actually been inside the window during
    // the current activation; otherwise it waits out a long grace first.
    property bool pointerSeen: false
    function revive() {
        coverFade.stop(); reshowCover.opacity = 1;
        win.reviving = true;
        var wasDead = win.pageDead; win.pageDead = false;
        web.visible = true;   // a Discarded view auto-Activates when shown
        if (win.pageParked) {
            win.pageParked = false;
            web.url = elementUrl;         // reload Element (session in the profile)
        } else if (wasDead) {
            web.reload();
        }
    }
    Timer {
        id: parkDiscard
        interval: (typeof discardMs !== "undefined" && discardMs > 0) ? discardMs : 600000
        repeat: false
        running: !win.active && web.visible && !win.pageDead && !win.pageParked
                 && web.lifecycleState === WebEngineView.LifecycleState.Active
        onTriggered: {
            // Park at about:blank FIRST: discarding the live Element page leaves
            // Chromium respawning a tiny renderer shell every ~12s forever
            // (service-worker/restore churn). A blank page has nothing to keep
            // alive, so blank + discard is fully quiescent — 0 renderers, 0 churn.
            win.pageParked = true;
            web.visible = false;
            web.url = "about:blank";      // the discard completes in onLoadingChanged
        }
    }

    // ── App-launcher-style background (mirrors appLauncher.qml mainBg) ──
    Rectangle {
        id: mainBg
        anchors.fill: parent
        radius: 16
        color: win.col("base", "#1e1e2e")
        border.color: win.col("surface1", "#45475a")
        border.width: 1
        clip: true

        // Timer-stepped at 20fps instead of a per-frame NumberAnimation (which
        // also had no gate at all): the blobs sweep 2π per 90s — sub-pixel per
        // 50ms step — and the render loop wakes 20x/s instead of every vsync.
        // Gated on win.active: the overlay auto-parks whenever it loses focus,
        // so active tracks "actually on screen".
        // Passive hover tracker for the travel guard (a HoverHandler never
        // consumes clicks/wheel, and Qt6 delivers hover to every item under
        // the cursor, so the web view is unaffected). onPointChanged rather
        // than onHoveredChanged: the activation reset can land AFTER the
        // enter-latch, and point keeps firing on every move inside.
        HoverHandler { onPointChanged: win.pointerSeen = true }

        property real orbit: 0
        Timer {
            interval: 50; repeat: true; running: win.active
            onTriggered: mainBg.orbit = (mainBg.orbit + Math.PI * 2 * 50 / 90000) % (Math.PI * 2)
        }

        // ambient blobs
        Rectangle {
            width: parent.width * 0.8; height: width; radius: width / 2
            x: (parent.width / 2 - width / 2) + Math.cos(mainBg.orbit * 2) * 100
            y: (parent.height / 2 - height / 2) + Math.sin(mainBg.orbit * 2) * 70
            opacity: 0.08
            color: win.col("mauve", "#cba6f7")
        }
        Rectangle {
            width: parent.width * 0.9; height: width; radius: width / 2
            x: (parent.width / 2 - width / 2) + Math.sin(mainBg.orbit * 1.5) * -100
            y: (parent.height / 2 - height / 2) + Math.cos(mainBg.orbit * 1.5) * -70
            opacity: 0.06
            color: win.col("blue", "#89b4fa")
        }
    }

    // ── Element Web on top, transparent so the background shows through ──
    // Persistent profile so the Matrix login/session survives restarts.
    WebEngineProfile {
        id: elementProfile
        storageName: "element-matrix"
        offTheRecord: false
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    }

    WebEngineView {
        id: web
        anchors.fill: parent
        anchors.margins: 2 + win.repaintKick   // +1px on re-show forces a repaint
        profile: elementProfile
        backgroundColor: "transparent"
        zoomFactor: 0.75            // shrink Element's UI to fit the smaller panel
        url: elementUrl

        // Inject the transparency script at DocumentCreation — BEFORE Element's
        // own scripts and its first paint — so the sweep is armed before any DOM
        // exists and the opaque theme never flashes (mirrors obsidian-shell's
        // userScripts approach). The LoadSucceeded + bootAssert runJavaScript
        // paths below stay as idempotent belt-and-braces. injectionPoint 2 =
        // DocumentCreation, worldId 0 = MainWorld.
        userScripts.collection: [{
            sourceCode: (typeof injectJs !== "undefined") ? injectJs : "",
            injectionPoint: 2,
            worldId: 0,
            runsOnSubFrames: true
        }]

        // injectJs (element_transparent.js) forces all backgrounds transparent —
        // including Shadow-DOM popovers — and self-persists via a MutationObserver.
        onLoadingChanged: function(req) {
            if (req.status === WebEngineView.LoadSucceeded) {
                if (win.pageParked) {         // about:blank arrived: finish the park
                    if (web.lifecycleState !== WebEngineView.LifecycleState.Active)
                        return;
                    web.lifecycleState = WebEngineView.LifecycleState.Discarded;
                    return;                   // (revive flips pageParked first, so a
                }                             //  show during this window wins the race)
                web.runJavaScript(injectJs);
                if (win.reviving) {           // revive path: page is back — re-assert
                    win.reviving = false;     // injection through SPA mount, then
                    bootAssert.n = 0;         // reveal exactly as on first boot.
                    bootAssert.running = true;
                    win.revealAfterRepaint();
                }
            } else if (req.status === WebEngineView.LoadFailedStatus && win.reviving) {
                win.reviving = false;         // don't leave the cover stuck over an
                coverFade.start();            // error page (element service down)
            }
        }
        onRenderProcessTerminated: function(status, code) {
            // A deliberate discard also reports its renderer going away — only a
            // termination while the page claims to be Active is a real crash.
            if (web.lifecycleState !== WebEngineView.LifecycleState.Active) return;
            win.pageDead = true;
            if (win.active) win.revive();     // crash while on screen: reload now;
        }                                     // parked: revived on next show
        // Re-assert while Element boots, in case the first load fires before its
        // root (and shadow roots) mount.
        Timer {
            id: bootAssert
            running: true; interval: 700; repeat: true
            property int n: 0
            // Active-gated: runJavaScript against a Discarded page force-revives
            // it (fresh renderer), which would silently undo the parked discard.
            onTriggered: {
                if (web.lifecycleState !== WebEngineView.LifecycleState.Active) return;
                web.runJavaScript(injectJs);
                if (++n > 14) running = false;
            }
        }
    }

    // ── Re-show cover ───────────────────────────────────────────────────────────
    // Sits ON TOP of the web view. forceRepaint() flips it opaque INSTANTLY when
    // the window reappears (hiding the parked surface's stale black buffer), the
    // web view repaints underneath, then it fades out — so re-opening only ever
    // shows the matugen colour, never black. No spinner, just the themed base.
    Rectangle {
        id: reshowCover
        anchors.fill: parent
        anchors.margins: 2
        radius: 14
        color: win.col("base", "#1e1e2e")
        opacity: 0
        visible: opacity > 0.01
        NumberAnimation on opacity {
            id: coverFade
            from: 1; to: 0; duration: 130; running: false; easing.type: Easing.OutCubic
        }
    }
}
