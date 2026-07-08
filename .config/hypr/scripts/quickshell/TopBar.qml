//@ pragma UseQApplication
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import Quickshell.Hyprland

// hyprland.conf additions:
//   windowrule { match:title = ^(qs-ai-response)$; float = on; center = on; size = 900 600 }

Variants {
    model: Quickshell.screens

    delegate: Component {
        PanelWindow {
            id: barWindow

            required property var modelData
            screen: modelData
            anchors { top: true; left: true; right: true }

            Scaler { id: scaler; currentWidth: barWindow.width }
            function s(val) { return scaler.s(val); }

            property int barHeight: s(48)
            implicitHeight: barHeight
            margins { top: s(8); bottom: 0; left: s(4); right: s(4) }
            exclusiveZone: barHeight + s(4)
            color: "transparent"

            MatugenColors { id: mocha }

            // ── State ──
            property bool isRecording: false
            property int workspaceCount: 8
            property bool isDesktop: false
            property string focusMode: "default"
            property bool hasNotifications: false
            property int focusEndEpoch: 0
            property int focusRemainSec: 0
            property bool focusWarned: false
            property string ethStatus: "Ethernet"
            property bool isStartupReady: false

            property bool startupCascadeFinished: false
            property bool fastPollerLoaded: false
            property bool isDataReady: fastPollerLoaded

            // ── Float state ──
            // Native Hyprland: floating state of the focused window (event-driven, no polling).
            // hyprTick is read so this rebinds when you toggle float on the *current* window
            // (activeToplevel keeps its identity; only its lastIpcObject updates, async).
            property bool currentWindowIsFloating: {
                barWindow.hyprTick;
                let t = Hyprland.activeToplevel;
                return (t && t.lastIpcObject) ? (t.lastIpcObject.floating === true) : false;
            }

            // Workspace-wide float MODE: true only when EVERY window on the active
            // workspace is floating (and there's at least one). The float toggle flips the
            // whole workspace at once, so the pill should mirror that mode — NOT the focused
            // window alone, which would light the pill up for a single auto-floated popup on
            // an otherwise-tiled workspace. Driven off hyprClients (event-settled via hyprTick).
            property bool workspaceIsFloating: {
                barWindow.hyprTick;
                let wsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -999;
                let wins = barWindow.hyprClients.filter(function(o) {
                    if (!o || !o.workspace || o.workspace.id !== wsId) return false;
                    // Shell overlays are immune to the float toggle (float_toggle.sh
                    // skips them) — exclude them from the mode read too, or an open
                    // popup makes a tiled workspace look like floating mode.
                    if (/^(element-matrix-overlay|home-assistant-overlay|athena|quickshell)$/.test(o.class || "")) return false;
                    if (/^(qs-master|mpv-pip-player)$/.test(o.title || "")) return false;
                    return true;
                });
                if (wins.length === 0) return false;
                return wins.every(function(o) { return o.floating === true; });
            }

            // ── Time / weather ──
            property string timeStr: ""
            property string fullDateStr: ""
            property int typeInIndex: 0
            property string dateStr: fullDateStr.substring(0, typeInIndex)
            property string weatherIcon: ""
            property string weatherTemp: "--°"
            property string weatherHex: mocha.yellow

            // ── System status ──
            property string wifiStatus: "Off"
            property string wifiIcon: "󰤮"
            property string wifiSsid: ""
            property string btStatus: "Off"
            property string btIcon: "󰂲"
            property string btDevice: ""
            property string kbLayout: "us"

            // ── Music ──
            property var musicData: ({ "status": "Stopped", "title": "", "artUrl": "", "timeStr": "" })

            // ── Derived ──
            property bool isMediaActive: musicData.status !== "Stopped" && musicData.title !== ""
            property bool isWifiOn: wifiStatus.toLowerCase() === "enabled" || wifiStatus.toLowerCase() === "on"
            property bool isBtOn: btStatus.toLowerCase() === "enabled" || btStatus.toLowerCase() === "on"
            property bool showEthernet: isDesktop && !isWifiOn

            // ── Dock clients / preview ──
            // A toplevel's `lastIpcObject` (which carries the class/geometry) is populated
            // ASYNCHRONOUSLY after the window appears, and that population does NOT change
            // the `toplevels.values` array identity — so a binding over `.values` alone
            // never re-runs once the data settles, and new windows get dropped (especially
            // when several open at once). `hyprTick` bumps on every Hyprland event (debounced
            // so the IPC data has settled) and is passed into the derived bindings to force a
            // re-evaluation. A slow periodic bump is a final safety net.
            property int hyprTick: 0
            property string _lastActiveAddr: ""
            Connections {
                target: Hyprland
                function onRawEvent(event) {
                    // Title-only events are pure churn here: nothing in the bar
                    // renders window titles, but a chatty title (terminal
                    // spinner, browser progress ticker) fires 4 events/sec and
                    // each used to trigger the full refetch+rebind cascade
                    // (~18ms). `activewindow` re-fires per title change of the
                    // focused window (it carries the title), so it's skipped
                    // too; real focus changes come through activewindowv2,
                    // deduped by address.
                    let n = event.name;
                    if (n === "windowtitle" || n === "windowtitlev2" || n === "activewindow") return;
                    if (n === "activewindowv2") {
                        if (event.data === barWindow._lastActiveAddr) return;
                        barWindow._lastActiveAddr = event.data;
                    }
                    hyprSettle.restart();
                }
            }
            Timer { id: hyprSettle; interval: 120; repeat: false; onTriggered: { Hyprland.refreshToplevels(); barWindow.hyprTick++ } }
            // Startup warm-up: a toplevel's lastIpcObject lands a beat after the window
            // appears, so pulse a few times early to populate the dock immediately on
            // launch, then stop. Real-time updates after that come from onRawEvent above.
            Timer {
                interval: 200; running: true; repeat: true
                property int pulses: 0
                onTriggered: { Hyprland.refreshToplevels(); barWindow.hyprTick++; if (++pulses >= 10) running = false }
            }
            // Slow safety net for anything the event handler misses (not the primary path).
            Timer { interval: 5000; running: true; repeat: true; onTriggered: { Hyprland.refreshToplevels(); barWindow.hyprTick++ } }

            function buildClients(_tick) {
                if (!Hyprland.toplevels) return [];
                // Overlay windows (parked on special workspaces, driven by their
                // own bar buttons) are not "apps" — keep them out of the dock.
                return Hyprland.toplevels.values.map(function(t) { return t.lastIpcObject; })
                                                .filter(function(o) { return o && o.class !== undefined
                                                    && o.class !== "element-matrix-overlay"
                                                    && o.class !== "home-assistant-overlay"; });
            }
            // Live client/window IPC objects (class, at, size, floating, workspace, monitor,
            // title). hyprTick is read here so this rebinds when windows settle.
            property var hyprClients: buildClients(barWindow.hyprTick)
            property int previewDockIndex: -1
            property int previewWsId: -1        // hovered workspace id (-1 = none)
            property real previewWsX: 0         // hovered workspace pill centre, in bar coords
            // Right-click dock menu, rendered as a real popup window (not clipped by the bar).
            property bool dockMenuOpen: false
            property int dockMenuIndex: -1
            property string dockMenuExec: ""
            property string dockMenuName: ""
            property string dockMenuIcon: ""
            // Middle-drag reorder state (cursor x within dockRow; "" = not dragging).
            property string dockDragKey: ""
            property real dockDragX: 0
            property string previewTitle: ""

            // A window preview stays up while the cursor is on the top bar OR on the preview
            // popup, and closes once it's on neither. Both HoverHandlers (barHover on the bar,
            // previewHover on the popup) call this; opening is still driven only by hovering an
            // app icon or workspace pill.
            function refreshPreviewHold() {
                if (barHover.hovered || previewHover.hovered) previewHideTimer.stop();
                else previewHideTimer.restart();
            }


            // ─────────────────────────────────────────────
            // HELPER FUNCTIONS
            // ─────────────────────────────────────────────
            // Convert workspace number (1-10) to standard Japanese kanji
            function toKanji(n) {
                let kanji = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"];
                let num = parseInt(n);
                if (num >= 1 && num <= 10) return kanji[num];
                return n; // fallback for >10
            }

            // Translates a "resolved" icon hint into a QML Image source.
            //
            // The crash we fixed: previously this returned "file://" + path
            // unconditionally, even when the file didn't exist. The Image
            // element would fail and onStatusChanged would re-set source to
            // image://icon/<fallback> — and that fallback chain has a known
            // bug in current Quickshell-git that crashes the entire process.
            //
            // Fix: prefer image://icon/ paths upfront. Only use file:// if we
            // got an absolute path that looks like a real desktop icon file
            // and ends in a known image extension. The Image element's
            // onStatusChanged handler is kept simple — single fallback, no
            // re-firing.
            function iconSource(resolved, fallbackName) {
                // No resolved icon → freedesktop icon name lookup
                if (!resolved || resolved === "") {
                    return "image://icon/" + fallbackName;
                }
                // Image provider URLs pass through
                if (resolved.startsWith("image://") || resolved.startsWith("qrc:")) {
                    return resolved;
                }
                // Bare name (no path, no extension) → freedesktop lookup
                if (resolved.indexOf("/") === -1) {
                    return "image://icon/" + resolved;
                }
                // Absolute path with image extension → file:// URL
                // (caller should pre-validate, but we accept it here)
                let lc = resolved.toLowerCase();
                if (resolved.startsWith("/") &&
                    (lc.endsWith(".png") || lc.endsWith(".svg") ||
                     lc.endsWith(".jpg") || lc.endsWith(".jpeg") ||
                     lc.endsWith(".xpm") || lc.endsWith(".ico"))) {
                    return "file://" + resolved;
                }
                // Anything else (weird paths, relative paths, etc.) — bail
                // to fallback rather than handing Image a broken URL.
                return "image://icon/" + fallbackName;
            }

            // `clients` is passed by the caller (read directly in the binding) so the
            // binding reactively tracks hyprClients — a bare reference inside the function
            // body gets optimized away and the dependency is lost.
            function clientsForApp(classNames, clients) {
                let result = [];
                let list = clients || hyprClients;
                for (let i = 0; i < list.length; i++) {
                    let c = list[i];
                    let cls = (c.class || "").toLowerCase();
                    if (cls.length < 2) continue;
                    for (let j = 0; j < classNames.length; j++) {
                        let key = (classNames[j] || "").toLowerCase();
                        if (key.length < 2) continue;
                        // Bidirectional substring so an exec basename matches the WM class
                        // even when one is longer, e.g. exec "zen-bin" vs class "zen", or
                        // exec "dolphin" vs class "org.kde.dolphin".
                        if (cls.indexOf(key) !== -1 || key.indexOf(cls) !== -1) {
                            result.push(c);
                            break;
                        }
                    }
                }
                return result;
            }

            // All HyprlandToplevel objects whose window class matches `key` (bidirectional,
            // same rule as clientsForApp). Returns the live toplevel objects (not just their
            // IPC json) so they can be fed to ScreencopyView for a live preview — works for
            // windows on ANY workspace, with no workspace switching.
            function toplevelsForApp(key, _tick, tops) {
                let out = [];
                let ts = tops || (Hyprland.toplevels ? Hyprland.toplevels.values : []);
                let k = (key || "").toLowerCase();
                if (k.length < 2) return out;
                for (let i = 0; i < ts.length; i++) {
                    let o = ts[i].lastIpcObject;
                    let cls = (o && o.class ? o.class : "").toLowerCase();
                    if (cls.length < 2) continue;
                    if (cls.indexOf(k) !== -1 || k.indexOf(cls) !== -1) out.push(ts[i]);
                }
                return out;
            }

            // All HyprlandToplevel objects on workspace `wsId` — fed to the same preview
            // tiles as the dock. (Windows on inactive workspaces aren't composited by
            // Hyprland, so their capture is the last rendered frame, not live.)
            function toplevelsForWorkspace(wsId, _tick, tops) {
                let out = [];
                let ts = tops || (Hyprland.toplevels ? Hyprland.toplevels.values : []);
                for (let i = 0; i < ts.length; i++) {
                    let o = ts[i].lastIpcObject;
                    if (o && o.workspace && o.workspace.id === wsId) out.push(ts[i]);
                }
                return out;
            }

            // ─────────────────────────────────────────────
            // STARTUP TIMERS
            // ─────────────────────────────────────────────
            Timer { interval: 10;   running: true; onTriggered: barWindow.isStartupReady = true }
            Timer { interval: 1000; running: true; onTriggered: barWindow.startupCascadeFinished = true }
            Timer { interval: 600;  running: true; onTriggered: barWindow.isDataReady = true }

            // Client/window list is now a native binding (hyprClients, above) — no
            // hyprctl poll or socat watcher needed.

            // Dock previews are now live native ScreencopyViews (see previewPopup) — no
            // grim screenshots, no /tmp files, and they work across all workspaces.

            // Float state is now a native binding (currentWindowIsFloating, above) —
            // no poller/socat watcher needed.

            // ─────────────────────────────────────────────
            // FOCUS MODE WATCHER
            // ─────────────────────────────────────────────
            // In-process watch (was a cat Process + inotifywait waiter pair — the
            // class that leaked orphans on restarts). The retry timer covers the
            // file-not-yet-created case the old `|| sleep 60` loop handled.
            FileView {
                id: focusModeView
                path: Quickshell.env("HOME") + "/.cache/qs_focus_mode"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: barWindow.focusMode = text().trim() || "default"
                onLoadFailed: focusModeRetry.start()
            }
            Timer { id: focusModeRetry; interval: 2000; repeat: false; onTriggered: focusModeView.reload() }

            // ── Dock assignment state (shared with the app launcher) ──
            // The launcher writes ~/.cache/qs_dock_state.json when you right-click an app
            // and assign it. We read gaming[] / studyRemoved[] here and match by `cmd` so
            // those assignments drive which dock icons show per focus mode — same rules:
            //   gaming-assigned → hidden in default & study (gaming only)
            //   study-removed   → hidden in study
            property var dockGaming: []
            property var dockStudyRemoved: []
            FileView {
                id: dockStateView
                path: Quickshell.env("HOME") + "/.cache/qs_dock_state.json"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: {
                    try {
                        let d = JSON.parse(text());
                        barWindow.dockGaming = d.gaming || [];
                        barWindow.dockStudyRemoved = d.studyRemoved || [];
                    } catch(e) {}
                }
                onLoadFailed: dockStateRetry.start()
            }
            Timer { id: dockStateRetry; interval: 2000; repeat: false; onTriggered: dockStateView.reload() }
            // ── Dynamic dock apps (managed from the launcher's right-click menu) ──
            // Read from ~/.cache/qs_dock_apps.json (array of {name,exec,icon});
            // defaults to just kitty when the file is missing/empty.
            property var dockAppsModel: [{ name: "kitty", exec: "kitty", icon: "kitty" }]
            FileView {
                id: dockAppsView
                path: Quickshell.env("HOME") + "/.cache/qs_dock_apps.json"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: {
                    let t = text().trim();
                    if (t === "") { barWindow.dockAppsModel = [{ name: "kitty", exec: "kitty", icon: "kitty" }]; return; }
                    try {
                        let arr = JSON.parse(t);
                        barWindow.dockAppsModel = (arr && arr.length > 0) ? arr
                            : [{ name: "kitty", exec: "kitty", icon: "kitty" }];
                    } catch(e) {}
                }
                onLoadFailed: dockAppsRetry.start()
            }
            Timer { id: dockAppsRetry; interval: 2000; repeat: false; onTriggered: dockAppsView.reload() }

            // Effective dock = pinned apps + TEMPORARY icons for any app that has an open
            // window but isn't pinned (taskbar-style). Rebuilt whenever the window set or
            // pinned set changes, but only reassigned when the actual app set differs — so
            // delegates aren't torn down every 500ms tick (which would kill the open/close
            // animations and reset the live window-dot counts). Temp entries carry temp:true.
            property var dockItems: barWindow.dockAppsModel
            function _dockSig(list) {
                if (!list) return "";
                let s = [];
                for (let i = 0; i < list.length; i++) s.push(list[i].exec);
                return s.join("|");
            }
            function rebuildDockItems() {
                let pinned = barWindow.dockAppsModel || [];
                let pinnedKeys = pinned.map(function(a) { return barWindow.dockKey(a.exec); });
                let clients = barWindow.hyprClients || [];
                let seen = {};
                let temps = [];
                for (let i = 0; i < clients.length; i++) {
                    let cls = (clients[i].class || "").toLowerCase();
                    if (cls.length < 2 || seen[cls]) continue;
                    let covered = false;
                    for (let j = 0; j < pinnedKeys.length; j++) {
                        let pk = pinnedKeys[j];
                        if (pk.length >= 2 && (cls.indexOf(pk) !== -1 || pk.indexOf(cls) !== -1)) { covered = true; break; }
                    }
                    if (covered) continue;
                    seen[cls] = true;
                    temps.push({ name: clients[i].class || cls, exec: cls, icon: cls, temp: true });
                }
                let next = pinned.concat(temps);
                if (barWindow._dockSig(next) !== barWindow._dockSig(barWindow.dockItems))
                    barWindow.dockItems = next;
            }
            onHyprClientsChanged: rebuildDockItems()
            onDockAppsModelChanged: rebuildDockItems()

            // ── Dock editing (writes the same files the launcher uses) ──
            function _saveDockApps(list) {
                // Persist only pinned {name,exec,icon} — drop transient temp entries.
                let pinned = list.filter(function(a){ return !a.temp; })
                                 .map(function(a){ return { name: a.name, exec: a.exec, icon: a.icon }; });
                Quickshell.execDetached(["bash","-c",'mkdir -p ~/.cache && printf %s "$1" > ~/.cache/qs_dock_apps.json',
                                         "qs-dock", JSON.stringify(pinned)]);
            }
            function dockIsPinned(exec) {
                let k = barWindow.dockKey(exec);
                for (let i = 0; i < barWindow.dockAppsModel.length; i++)
                    if (barWindow.dockKey(barWindow.dockAppsModel[i].exec) === k) return true;
                return false;
            }
            function dockPin(name, exec, icon) {
                if (barWindow.dockIsPinned(exec)) return;
                let next = barWindow.dockAppsModel.concat([{ name: name, exec: exec, icon: icon }]);
                barWindow.dockAppsModel = next; barWindow._saveDockApps(next);
            }
            function dockUnpin(exec) {
                let k = barWindow.dockKey(exec);
                let next = barWindow.dockAppsModel.filter(function(a){ return barWindow.dockKey(a.exec) !== k; });
                barWindow.dockAppsModel = next; barWindow._saveDockApps(next);
            }
            // Middle-drag drop: move the dragged pinned app into the slot under the cursor.
            function dockDragEnd() {
                let pinned = barWindow.dockAppsModel;
                let k = barWindow.dockDragKey;
                barWindow.dockDragKey = "";              // clear first so the icon snaps to its slot
                if (!k || pinned.length < 2) return;
                let cur = -1;
                for (let i = 0; i < pinned.length; i++) if (barWindow.dockKey(pinned[i].exec) === k) { cur = i; break; }
                if (cur < 0) return;
                let stride = barWindow.s(36) + barWindow.s(6);
                let target = Math.round((barWindow.dockDragX - barWindow.s(18)) / stride);
                if (target < 0) target = 0;
                if (target > pinned.length - 1) target = pinned.length - 1;
                if (target === cur) return;
                let list = pinned.slice();
                let item = list.splice(cur, 1)[0];
                list.splice(target, 0, item);
                barWindow.dockAppsModel = list; barWindow._saveDockApps(list);
            }
            // Run a right-click menu action against barWindow.dockMenuExec.
            function dockMenuAction(act) {
                let exec = barWindow.dockMenuExec;
                if (act === "pin") {
                    if (barWindow.dockIsPinned(exec)) barWindow.dockUnpin(exec);
                    else barWindow.dockPin(barWindow.dockMenuName, exec, barWindow.dockMenuIcon);
                } else if (act === "gaming") {
                    barWindow.dockToggleGaming(exec);
                } else if (act === "study") {
                    barWindow.dockToggleStudy(exec);
                } else if (act === "close") {
                    let cs = barWindow.clientsForApp([barWindow.dockKey(exec)], barWindow.hyprClients);
                    if (cs.length > 0) Hyprland.dispatch("closewindow address:" + cs[cs.length - 1].address);
                }
            }
            // Gaming/Study assignment — writes qs_dock_state.json (same as the launcher).
            function _saveDockState() {
                let obj = { gaming: barWindow.dockGaming, studyRemoved: barWindow.dockStudyRemoved };
                Quickshell.execDetached(["bash","-c",'mkdir -p ~/.cache && printf %s "$1" > ~/.cache/qs_dock_state.json',
                                         "qs-dock", JSON.stringify(obj)]);
            }
            function dockToggleGaming(exec) {
                let k = barWindow.dockKey(exec);
                if (barWindow.dockGaming.indexOf(k) >= 0) barWindow.dockGaming = barWindow.dockGaming.filter(function(n){return n!==k;});
                else barWindow.dockGaming = barWindow.dockGaming.concat([k]);
                barWindow._saveDockState();
            }
            function dockToggleStudy(exec) {
                let k = barWindow.dockKey(exec);
                if (barWindow.dockStudyRemoved.indexOf(k) >= 0) barWindow.dockStudyRemoved = barWindow.dockStudyRemoved.filter(function(n){return n!==k;});
                else barWindow.dockStudyRemoved = barWindow.dockStudyRemoved.concat([k]);
                barWindow._saveDockState();
            }

            // Reduce an exec string to its command key (basename) — matches the
            // launcher's _cmdKey, e.g. "/usr/bin/steam %U" → "steam".
            function dockKey(execStr) {
                if (!execStr || typeof execStr !== "string") return "";
                let parts = execStr.trim().split(/\s+/);
                let i = 0;
                while (i < parts.length && (parts[i] === "env" || parts[i].indexOf("=") >= 0)) i++;
                let bin = parts[i] || "";
                let slash = bin.lastIndexOf("/");
                if (slash >= 0) bin = bin.substring(slash + 1);
                return bin.toLowerCase();
            }
            // True if this dock app is hidden in the current focus mode, based on the
            // launcher's saved gaming/study assignments (keyed by command).
            function dockAppHidden(execStr) {
                let key = barWindow.dockKey(execStr);
                for (let i = 0; i < barWindow.dockGaming.length; i++)
                    if (barWindow.dockGaming[i] === key && barWindow.focusMode !== "gaming") return true;
                if (barWindow.focusMode === "study")
                    for (let j = 0; j < barWindow.dockStudyRemoved.length; j++)
                        if (barWindow.dockStudyRemoved[j] === key) return true;
                return false;
            }

            // ── System-tray hide list (middle-click an icon to hide it) ──────────
            // Persisted in ~/.cache/qs_tray_hidden.json. Steam is special-cased in
            // trayShouldShow: it's only shown in gaming mode, regardless of this list.
            property var trayHidden: []
            property bool trayExpanded: false   // arrow-toggled overflow drawer
            function trayId(item) {
                if (!item) return "";
                return (item.id || "") + "|" + (item.title || "");
            }
            function trayIsSteam(item) {
                let s = ((item && item.id ? item.id : "") + " " + (item && item.title ? item.title : "")).toLowerCase();
                return s.indexOf("steam") >= 0;
            }
            function trayShouldShow(item) {
                if (barWindow.trayIsSteam(item)) return barWindow.focusMode === "gaming";
                // Hidden icons live in the overflow drawer — only shown when expanded.
                if (barWindow.trayHidden.indexOf(barWindow.trayId(item)) >= 0) return barWindow.trayExpanded;
                return true;
            }
            function saveTrayHidden() {
                Quickshell.execDetached(["bash","-c",'mkdir -p ~/.cache && printf %s "$1" > ~/.cache/qs_tray_hidden.json',
                                         "qs-tray", JSON.stringify(barWindow.trayHidden)]);
            }
            function trayToggleHide(item) {
                let id = barWindow.trayId(item);
                if (id === "|") return;
                if (barWindow.trayHidden.indexOf(id) >= 0)
                    barWindow.trayHidden = barWindow.trayHidden.filter(function(n){ return n !== id; });
                else
                    barWindow.trayHidden = barWindow.trayHidden.concat([id]);
                barWindow.saveTrayHidden();
            }
            FileView {
                id: trayHiddenView
                path: Quickshell.env("HOME") + "/.cache/qs_tray_hidden.json"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: { try { barWindow.trayHidden = JSON.parse(text()) || []; } catch(e) {} }
                // Missing file = nothing hidden; no retry needed (created on first save,
                // and watchChanges picks it up via reload once saveTrayHidden writes it).
                onLoadFailed: trayHiddenRetry.start()
            }
            Timer { id: trayHiddenRetry; interval: 5000; repeat: false; onTriggered: trayHiddenView.reload() }

            // ── Gaming mode: quit gaming-assigned apps when leaving gaming mode ───
            property string prevFocusMode: "default"
            onFocusModeChanged: {
                if (barWindow.prevFocusMode === "gaming" && barWindow.focusMode !== "gaming")
                    barWindow.closeGamingApps();
                barWindow.prevFocusMode = barWindow.focusMode;
            }
            function closeGamingApps() {
                let keys = barWindow.dockGaming || [];
                let parts = [];
                for (let i = 0; i < keys.length; i++) {
                    let k = String(keys[i]).replace(/[^A-Za-z0-9._-]/g, "");
                    if (k === "") continue;
                    // Close any open windows of the app, then quit the process — Steam
                    // gets a clean -shutdown; others a graceful pkill by exact name.
                    parts.push(
                        "hyprctl clients -j 2>/dev/null | jq -r --arg k \"" + k + "\" '.[]|select((.class|ascii_downcase)|contains($k))|.address' 2>/dev/null | while read -r a; do hyprctl dispatch closewindow address:$a; done; "
                        + (k === "steam" ? "steam -shutdown >/dev/null 2>&1 || pkill -x steam 2>/dev/null; "
                                         : "pkill -x \"" + k + "\" 2>/dev/null; ")
                    );
                }
                if (parts.length > 0) Quickshell.execDetached(["bash","-c", parts.join("")]);
            }

            // ── Focus end epoch reader ──
            FileView {
                id: focusEndView
                path: Quickshell.env("HOME") + "/.cache/qs_focus_end"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: {
                    let val = parseInt(text().trim()) || 0;
                    if (val !== barWindow.focusEndEpoch) {
                        barWindow.focusEndEpoch = val;
                        barWindow.focusWarned = false;
                    }
                }
                onLoadFailed: focusEndRetry.start()
            }
            Timer { id: focusEndRetry; interval: 2000; repeat: false; onTriggered: focusEndView.reload() }

            // ── Notification dot tracker ──
            // The dbus pipeline stays (it's a bus watch, not a file); it now touches
            // the dot file upfront so the FileView below can establish its watch.
            Process {
                id: notifDotWatcher; running: true
                command: ["bash", "-c",
                    "touch /tmp/qs_bell_dot; " +
                    "dbus-monitor --session \"member='Notify',interface='org.freedesktop.Notifications'\" 2>/dev/null | " +
                    "while read -r line; do " +
                    "  if echo \"$line\" | grep -q 'member=Notify'; then " +
                    "    echo 1 > /tmp/qs_bell_dot; " +
                    "  fi; " +
                    "done"
                ]
            }
            FileView {
                id: bellDotView
                path: "/tmp/qs_bell_dot"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: barWindow.hasNotifications = text().trim() === "1"
                onLoadFailed: bellDotRetry.start()
            }
            Timer { id: bellDotRetry; interval: 2000; repeat: false; onTriggered: bellDotView.reload() }

            // ── Universal focus countdown (always running) ──
            Timer {
                id: focusCountdownTimer
                interval: 1000; repeat: true
                running: barWindow.focusMode !== "default" && barWindow.focusEndEpoch > 0
                onTriggered: {
                    let now = Math.floor(Date.now() / 1000);
                    barWindow.focusRemainSec = Math.max(0, barWindow.focusEndEpoch - now);

                    // 5-minute warning for study mode (only once)
                    if (barWindow.focusMode === "study" && !barWindow.focusWarned
                        && barWindow.focusRemainSec <= 300 && barWindow.focusRemainSec > 0) {
                        barWindow.focusWarned = true;
                        Quickshell.execDetached(["bash", "-c",
                            "~/.config/hypr/scripts/qs_manager.sh toggle focuswarn"
                        ]);
                    }

                    // Timer expired — switch back to default
                    if (barWindow.focusRemainSec <= 0) {
                        barWindow.focusMode = "default";
                        barWindow.focusEndEpoch = 0;
                        barWindow.focusWarned = false;
                        Quickshell.execDetached(["bash", "-c",
                            "echo default > ~/.cache/qs_focus_mode; echo 0 > ~/.cache/qs_focus_end; " +
                            "notify-send -u critical 'Focus Mode' 'Time is up! Switched back to Default.'"
                        ]);
                        // The FileView watch picks up the write above and re-syncs on its own.
                    }
                }
            }

            // ─────────────────────────────────────────────
            // RECORDING POLLER
            // ─────────────────────────────────────────────
            // Direct pgrep, no bash wrapper (halves the 24/7 fork rate of this poll);
            // detection rides the exit code: 0 = found, 1 = none.
            Process {
                id: recPoller
                command: ["pgrep", "-x", "wl-screenrec"]
                onExited: (exitCode) => { barWindow.isRecording = (exitCode === 0); }
            }
            Timer {
                interval: 500; running: true; repeat: true
                onTriggered: { recPoller.running = false; recPoller.running = true; }
            }

            // ─────────────────────────────────────────────
            // SETTINGS WATCHER
            // ─────────────────────────────────────────────
            FileView {
                id: settingsView
                path: Quickshell.env("HOME") + "/.config/hypr/settings.json"
                watchChanges: true
                onFileChanged: reload()
                onLoaded: {
                    try {
                        let parsed = JSON.parse(text());
                        if (parsed.workspaceCount !== undefined && barWindow.workspaceCount !== parsed.workspaceCount) {
                            barWindow.workspaceCount = parsed.workspaceCount;
                        }
                    } catch(e) {}
                }
                onLoadFailed: settingsRetry.start()
            }
            Timer { id: settingsRetry; interval: 2000; repeat: false; onTriggered: settingsView.reload() }

            // ─────────────────────────────────────────────
            // CHASSIS DETECTION
            // ─────────────────────────────────────────────
            Process {
                id: chassisDetector; running: true
                command: ["bash", "-c", "if ls /sys/class/power_supply/BAT* 1>/dev/null 2>&1; then echo 'laptop'; else echo 'desktop'; fi"]
                stdout: StdioCollector {
                    onStreamFinished: { barWindow.isDesktop = (this.text.trim() === "desktop"); }
                }
            }

            // ─────────────────────────────────────────────
            // WORKSPACES (native Hyprland — no daemon/socat/inotify)
            // ─────────────────────────────────────────────
            // State for workspace `id`: "active" (focused), "occupied" (has windows),
            // or "" (empty). Reactively driven by Hyprland.workspaces / focusedWorkspace.
            function wsStateFor(id, _tick, focused) {
                if (focused && focused.id === id) return "active";
                // Occupied = any window currently lives on this workspace. Derived from
                // toplevels (reactive) rather than the per-workspace window count, which
                // Hyprland doesn't always refresh promptly.
                if (Hyprland.toplevels) {
                    let ts = Hyprland.toplevels.values;
                    for (let i = 0; i < ts.length; i++) {
                        let o = ts[i].lastIpcObject;
                        if (o && o.workspace && o.workspace.id === id) return "occupied";
                    }
                }
                return "";
            }

            // ─────────────────────────────────────────────
            // MUSIC
            // ─────────────────────────────────────────────
            Process {
                id: musicForceRefresh; running: true
                command: ["bash", "-c", "bash ~/.config/hypr/scripts/quickshell/music/music_info.sh | tee /tmp/music_info.json"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        let txt = this.text.trim();
                        if (txt !== "") { try { barWindow.musicData = JSON.parse(txt); } catch(e) {} }
                    }
                }
            }
            // Only ticks while actually playing — no wakeups when paused/stopped.
            Timer {
                interval: 1000; repeat: true
                running: barWindow.musicData.status === "Playing"
                onTriggered: {
                    if (!barWindow.musicData || barWindow.musicData.status !== "Playing") return;
                    if (!barWindow.musicData.timeStr || barWindow.musicData.timeStr === "") return;
                    let parts = barWindow.musicData.timeStr.split(" / ");
                    if (parts.length !== 2) return;
                    let pp = parts[0].split(":").map(Number);
                    let lp = parts[1].split(":").map(Number);
                    let pos = (pp.length === 3) ? (pp[0]*3600+pp[1]*60+pp[2]) : (pp[0]*60+pp[1]);
                    let len = (lp.length === 3) ? (lp[0]*3600+lp[1]*60+lp[2]) : (lp[0]*60+lp[1]);
                    if (isNaN(pos) || isNaN(len)) return;
                    pos++; if (pos > len) pos = len;
                    let ps = "";
                    if (pp.length === 3) {
                        let h=Math.floor(pos/3600),m=Math.floor((pos%3600)/60),s=pos%60;
                        ps=h+":"+(m<10?"0":"")+m+":"+(s<10?"0":"")+s;
                    } else {
                        let m=Math.floor(pos/60),s=pos%60;
                        ps=(m<10?"0":"")+m+":"+(s<10?"0":"")+s;
                    }
                    let nd = Object.assign({}, barWindow.musicData);
                    nd.timeStr = ps + " / " + parts[1];
                    nd.positionStr = ps;
                    if (len > 0) nd.percent = (pos/len)*100;
                    barWindow.musicData = nd;
                }
            }
            Process {
                id: mprisWatcher; running: true
                command: ["bash", "-c", "dbus-monitor --session \"type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.mpris.MediaPlayer2.Player'\" \"type='signal',interface='org.mpris.MediaPlayer2.Player',member='Seeked'\" 2>/dev/null | grep -m1 'member=' >/dev/null || sleep 2"]
                onExited: { musicForceRefresh.running = false; musicForceRefresh.running = true; running = false; running = true; }
            }

            // ─────────────────────────────────────────────
            // SYSTEM WATCHERS
            // ─────────────────────────────────────────────
            // Initial read only: get the true input mode once at launch. There is NO poll
            // loop anymore — the pill updates event-driven, off the click (see kbAction).
            Process {
                id: kbPoller; running: true
                command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/watchers/kb_fetch.sh"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        let t = this.text.trim();
                        if (t !== "" && barWindow.kbLayout !== t) barWindow.kbLayout = t;
                        barWindow.fastPollerLoaded = true;
                    }
                }
            }
            // The kb pill performs its toggle / language switch THROUGH this process: the
            // click handler sets `command` to "<do the action> ; re-read kb_fetch.sh", so the
            // label reconciles to the real fcitx5 state in the same shell right after a click.
            // This replaces the old kb_wait.sh 1.5s poll (which spawned bash ×3 monitors every
            // 1.5s and was the main steady feeder of ananicy-cpp).
            Process {
                id: kbAction
                stdout: StdioCollector {
                    onStreamFinished: {
                        let lines = this.text.trim().split("\n");
                        let t = lines[lines.length - 1].trim();   // last line = kb_fetch result
                        if (t !== "" && barWindow.kbLayout !== t) barWindow.kbLayout = t;
                    }
                }
            }

            Process {
                id: networkPoller; running: true
                command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/watchers/network_fetch.sh"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        let t = this.text.trim();
                        if (t !== "") {
                            try {
                                let d = JSON.parse(t);
                                if (barWindow.wifiStatus !== d.status) barWindow.wifiStatus = d.status;
                                if (barWindow.wifiIcon !== d.icon) barWindow.wifiIcon = d.icon;
                                if (barWindow.wifiSsid !== d.ssid) barWindow.wifiSsid = d.ssid;
                                if (barWindow.ethStatus !== d.eth_status) barWindow.ethStatus = d.eth_status;
                            } catch(e) {}
                        }
                        networkWaiter.running = false; networkWaiter.running = true;
                    }
                }
            }
            Process { id: networkWaiter; command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/watchers/network_wait.sh"]; onExited: { networkPoller.running = false; networkPoller.running = true; } }

            Process {
                id: btPoller; running: true
                command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/watchers/bt_fetch.sh"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        let t = this.text.trim();
                        if (t !== "") {
                            try {
                                let d = JSON.parse(t);
                                if (barWindow.btStatus !== d.status) barWindow.btStatus = d.status;
                                if (barWindow.btIcon !== d.icon) barWindow.btIcon = d.icon;
                                if (barWindow.btDevice !== d.connected) barWindow.btDevice = d.connected;
                            } catch(e) {}
                        }
                        btWaiter.running = false; btWaiter.running = true;
                    }
                }
            }
            Process { id: btWaiter; command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/watchers/bt_wait.sh"]; onExited: { btPoller.running = false; btPoller.running = true; } }

            Process {
                id: weatherPoller
                // Fire once at launch: this both shows the cached value immediately AND arms
                // weatherWaiter (in onStreamFinished) so later calendar/refresh writes re-poll.
                // Without this initial run nothing ever starts the read↔watch chain.
                running: true
                // READ-ONLY: --current-ro prints icon/temp/hex straight from the cache and
                // never fetches/writes. The old --current-icon/temp/hex calls re-ran get_data
                // (which rewrites weather.json) on every poll while current_* was empty — with
                // no API key that's permanent, and the cache watcher below turned it into a
                // fork-storm feedback loop. One read-only call can't trigger that.
                command: ["bash", "-c",
                    "~/.config/hypr/scripts/quickshell/calendar/weather.sh --current-ro"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        // Strip only TRAILING newlines — a blank first line (empty icon) is
                        // significant and trim() would drop it, shifting temp/hex up a slot.
                        let lines = this.text.replace(/\n+$/, "").split("\n");
                        if (lines.length >= 3) {
                            barWindow.weatherIcon = lines[0];
                            barWindow.weatherTemp = lines[1];
                            barWindow.weatherHex = lines[2] || mocha.yellow;
                        }
                        // Re-arm the cache watcher so a genuine (external) refresh re-polls us.
                        weatherWaiter.running = false; weatherWaiter.running = true;
                    }
                }
            }
            // Event-driven sync with the calendar: weather_wait.sh blocks until the shared
            // weather.json cache is rewritten (the calendar's refresh is what does that),
            // then exits so we re-read immediately — topbar weather tracks the calendar's.
            Process {
                id: weatherWaiter
                command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/watchers/weather_wait.sh"]
                onExited: { weatherPoller.running = false; weatherPoller.running = true; }
            }
            // Fetch fresh weather data every 10 minutes. --fetch runs get_data in the
            // foreground and exits the moment it's done (Quickshell reaps it immediately —
            // nothing lingers); its write to weather.json then trips weatherWaiter above,
            // which re-reads the display. The shell-side lock + age gate means the 3
            // per-monitor copies of this don't actually fetch 3 times.
            Process {
                id: weatherRefresh
                command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/calendar/weather.sh --fetch"]
            }
            // Once-per-launch refresh: `running: true` fires exactly once when this bar is
            // created — i.e. on every reload/login. Passing a small max-age (30s) forces a
            // fresh fetch regardless of cache age (the periodic --fetch above keeps its 540s
            // gate). Its write to weather.json trips weatherWaiter, updating the display.
            Process {
                id: weatherStartupRefresh
                running: true
                command: ["bash", "-c", "~/.config/hypr/scripts/quickshell/calendar/weather.sh --fetch 30"]
            }
            Timer {
                interval: 600000; running: true; repeat: true; triggeredOnStart: false
                onTriggered: { weatherRefresh.running = false; weatherRefresh.running = true; }
            }

            Timer {
                interval: 1000; running: true; repeat: true; triggeredOnStart: true
                onTriggered: {
                    let d = new Date();
                    barWindow.timeStr = Qt.formatDateTime(d, "HH:mm:ss");
                    barWindow.fullDateStr = Qt.formatDateTime(d, "dddd, MMMM dd");
                    if (barWindow.typeInIndex >= barWindow.fullDateStr.length)
                        barWindow.typeInIndex = barWindow.fullDateStr.length;
                }
            }
            Timer {
                id: typewriterTimer; interval: 40
                running: barWindow.isStartupReady && barWindow.typeInIndex < barWindow.fullDateStr.length
                repeat: true
                onTriggered: barWindow.typeInIndex += 1
            }

            // =====================================================
            // UI LAYOUT
            // =====================================================
            Item {
                anchors.fill: parent

                // Whole-bar hover tracker — keeps a window preview open while the cursor is
                // anywhere on the bar (paired with previewHover on the popup).
                HoverHandler { id: barHover; onHoveredChanged: barWindow.refreshPreviewHold() }

                // ── LEFT: Matrix chat button + Dock ──
                Row {
                    id: leftBar
                    y: (parent.height - barWindow.barHeight) / 2
                    spacing: barWindow.s(4)
                    property bool showLayout: false
                    opacity: showLayout ? 1 : 0
                    x: showLayout ? 0 : barWindow.s(-300)
                    Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }
                    Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    Timer { running: barWindow.isStartupReady; interval: 10; onTriggered: leftBar.showLayout = true }

                    // Character sheet button (far left) — opens the Life-OS HEXACO widget.
                    Rectangle {
                        id: aiBtn
                        property bool isHovered: aiMouse.containsMouse
                        color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.95) : Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75)
                        radius: barWindow.s(14); border.width: 1
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, isHovered ? 0.15 : 0.05)
                        height: barWindow.barHeight; width: barWindow.barHeight
                        Behavior on color { ColorAnimation { duration: 200 } }
                        scale: isHovered ? 1.05 : 1.0
                        Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }

                        Text {
                            anchors.centerIn: parent; text: "󰙋"
                            font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(26)
                            color: aiBtn.isHovered ? mocha.green : mocha.subtext0
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }
                        MouseArea {
                            id: aiMouse; anchors.fill: parent; hoverEnabled: true
                            onClicked: function(mouse) {
                                mouse.accepted = true;
                                Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle charactersheet"]);
                            }
                        }
                    }

                    // Dock
                    Rectangle {
                        id: dockBox
                        color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75)
                        radius: barWindow.s(14); border.width: 1
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.05)
                        // Height accounts for icon + dot indicator below
                        height: barWindow.barHeight
                        width: dockRow.implicitWidth + barWindow.s(20)
                        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }
                        clip: false

                        Row {
                            id: dockRow
                            anchors.centerIn: parent
                            spacing: barWindow.s(6)

                            Repeater {
                                model: barWindow.dockItems
                                delegate: Item {
                                    id: dockItemWrapper
                                    // Capture the model fields as typed strings so bindings
                                    // never see a wrapped object during model resets.
                                    property string appExec: (modelData && modelData.exec) ? modelData.exec : ""
                                    property string appIcon: (modelData && modelData.icon) ? modelData.icon : ""
                                    property string appName: (modelData && modelData.name) ? modelData.name : ""
                                    // Hidden if a launcher assignment (gaming-only /
                                    // study-removed) hides it in the current focus mode.
                                    property bool isHidden: barWindow.dockAppHidden(appExec)
                                    visible: !isHidden
                                    width: visible ? barWindow.s(36) : 0
                                    height: visible ? barWindow.s(40) : 0
                                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

                                    // Pass hyprClients as an arg so the binding tracks it.
                                    property var appClients: barWindow.clientsForApp([barWindow.dockKey(appExec)], barWindow.hyprClients)
                                    property int windowCount: appClients.length
                                    property bool hasWindows: windowCount > 0
                                    property bool isHovered: dockMouse.containsMouse

                                    property bool initAnimTrigger: false
                                    opacity: initAnimTrigger ? 1 : 0
                                    transform: Translate {
                                        y: dockItemWrapper.initAnimTrigger ? 0 : barWindow.s(15)
                                        Behavior on y { NumberAnimation { duration: 500; easing.type: Easing.OutBack } }
                                    }
                                    Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

                                    Timer {
                                        running: leftBar.showLayout && !dockItemWrapper.initAnimTrigger
                                        interval: 60 + index * 60
                                        onTriggered: dockItemWrapper.initAnimTrigger = true
                                    }

                                    // Icon background pill
                                    Rectangle {
                                        id: dockIconBg
                                        anchors.top: parent.top
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: barWindow.s(36); height: barWindow.s(32)
                                        radius: barWindow.s(10)
                                        // While middle-drag reordering, this icon follows the cursor.
                                        property bool dragging: barWindow.dockDragKey !== "" && barWindow.dockDragKey === barWindow.dockKey(dockItemWrapper.appExec)
                                        z: dragging ? 100 : 0
                                        opacity: dragging ? 0.85 : 1.0
                                        transform: Translate { x: dockIconBg.dragging ? (barWindow.dockDragX - (dockItemWrapper.x + dockItemWrapper.width / 2)) : 0 }
                                        color: dockItemWrapper.isHovered
                                            ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.9)
                                            : (dockItemWrapper.hasWindows
                                                ? Qt.rgba(mocha.surface0.r, mocha.surface0.g, mocha.surface0.b, 0.45)
                                                : "transparent")
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                        scale: dockItemWrapper.isHovered ? 1.12 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                                        Image {
                                            id: dockIconImage
                                            anchors.centerIn: parent
                                            width: barWindow.s(22); height: barWindow.s(22)
                                            source: barWindow.iconSource(dockItemWrapper.appIcon, dockItemWrapper.appIcon)
                                            fillMode: Image.PreserveAspectFit; smooth: true
                                            // Guard against infinite fallback loops. If the freedesktop
                                            // icon provider also fails, we just leave the Image empty
                                            // rather than re-firing onStatusChanged which can crash
                                            // Quickshell-git on some Qt 6.11 builds.
                                            property bool fallbackTried: false
                                            onStatusChanged: {
                                                if (status === Image.Error && !fallbackTried) {
                                                    fallbackTried = true;
                                                    source = "image://icon/" + dockItemWrapper.appIcon;
                                                } else if (status === Image.Error && fallbackTried) {
                                                    // Already tried fallback; give up silently.
                                                    source = "";
                                                }
                                            }
                                        }
                                    }

                                    // Open window dots (1 per window, max 4)
                                    Row {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        spacing: barWindow.s(3)
                                        visible: dockItemWrapper.hasWindows
                                        Repeater {
                                            model: Math.min(dockItemWrapper.windowCount, 4)
                                            delegate: Rectangle {
                                                width: barWindow.s(4); height: barWindow.s(4)
                                                radius: width / 2
                                                color: mocha.mauve; opacity: 0.85
                                            }
                                        }
                                    }

                                    // Hover → show preview after 400ms
                                    Timer {
                                        id: previewHoverTimer; interval: 400; repeat: false
                                        running: dockItemWrapper.isHovered && dockItemWrapper.hasWindows
                                        onTriggered: {
                                            if (!dockItemWrapper.isHovered || !dockItemWrapper.hasWindows) return;
                                            barWindow.previewDockIndex = index;
                                            // The popup shows live ScreencopyViews for every window of
                                            // this app (any workspace); just label it with the app name.
                                            barWindow.previewTitle = dockItemWrapper.appName;
                                        }
                                    }

                                    MouseArea {
                                        id: dockMouse; anchors.fill: parent; hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                        preventStealing: true
                                        // Middle-drag to reorder: pick up on press, follow on move,
                                        // drop into the slot under the cursor on release.
                                        onPressed: function(mouse) {
                                            if (mouse.button === Qt.MiddleButton && barWindow.dockIsPinned(dockItemWrapper.appExec)) {
                                                barWindow.dockDragKey = barWindow.dockKey(dockItemWrapper.appExec);
                                                barWindow.dockDragX = dockItemWrapper.x + mouse.x;
                                            }
                                        }
                                        onPositionChanged: function(mouse) {
                                            if (barWindow.dockDragKey !== "" && barWindow.dockDragKey === barWindow.dockKey(dockItemWrapper.appExec))
                                                barWindow.dockDragX = dockItemWrapper.x + mouse.x;
                                        }
                                        onReleased: function(mouse) {
                                            if (mouse.button === Qt.MiddleButton && barWindow.dockDragKey !== "")
                                                barWindow.dockDragEnd();
                                        }
                                        onClicked: function(mouse) {
                                            if (mouse.button === Qt.RightButton) {
                                                barWindow.dockMenuExec = dockItemWrapper.appExec;
                                                barWindow.dockMenuName = dockItemWrapper.appName;
                                                barWindow.dockMenuIcon = dockItemWrapper.appIcon;
                                                barWindow.dockMenuIndex = index;
                                                barWindow.dockMenuOpen = true;
                                            } else if (mouse.button === Qt.LeftButton) {
                                                Quickshell.execDetached(["bash", "-c", dockItemWrapper.appExec]);
                                            }
                                            // middle button is handled by the drag above
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── MEDIA PLAYER ──
                Rectangle {
                    id: mediaBox
                    color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75)
                    radius: barWindow.s(14); border.width: 1; border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.05)
                    y: (parent.height - barWindow.barHeight) / 2
                    height: barWindow.barHeight; clip: true
                    property real targetWidth: barWindow.isMediaActive ? mediaLayoutContainer.width + barWindow.s(24) : 0
                    x: leftBar.x + leftBar.width + barWindow.s(8)
                    Behavior on x { enabled: barWindow.startupCascadeFinished; NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }
                    width: targetWidth
                    visible: targetWidth > 0 || opacity > 0
                    opacity: barWindow.isMediaActive ? 1.0 : 0.0
                    Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutQuint } }
                    Behavior on opacity { NumberAnimation { duration: 400 } }

                    Item {
                        id: mediaLayoutContainer
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left; anchors.leftMargin: barWindow.s(12)
                        height: parent.height; width: innerMediaLayout.width
                        opacity: barWindow.isMediaActive ? 1.0 : 0.0
                        transform: Translate { x: barWindow.isMediaActive ? 0 : barWindow.s(-20); Behavior on x { NumberAnimation { duration: 700; easing.type: Easing.OutQuint } } }
                        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

                        Row {
                            id: innerMediaLayout
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: barWindow.width < 1920 ? barWindow.s(8) : barWindow.s(16)

                            MouseArea {
                                id: mediaInfoMouse; width: infoLayout.width; height: innerMediaLayout.height; hoverEnabled: true
                                onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle music"])
                                Row {
                                    id: infoLayout; anchors.verticalCenter: parent.verticalCenter; spacing: barWindow.s(10)
                                    scale: mediaInfoMouse.containsMouse ? 1.02 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                                    Rectangle {
                                        width: barWindow.s(32); height: barWindow.s(32); radius: barWindow.s(8); color: mocha.surface1
                                        border.width: barWindow.musicData.status === "Playing" ? 1 : 0; border.color: mocha.mauve; clip: true
                                        Image { anchors.fill: parent; source: barWindow.musicData.artUrl || ""; fillMode: Image.PreserveAspectCrop }
                                        Rectangle { anchors.fill: parent; color: Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.2) }
                                    }
                                    Column {
                                        spacing: -2; anchors.verticalCenter: parent.verticalCenter
                                        width: barWindow.width < 1920 ? barWindow.s(120) : barWindow.s(180)
                                        Text { text: barWindow.musicData.title; textFormat: Text.PlainText; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: barWindow.s(13); color: mocha.text; width: parent.width; elide: Text.ElideRight }
                                        Text { text: barWindow.musicData.timeStr; font.family: "JetBrains Mono"; font.weight: Font.Black; font.pixelSize: barWindow.s(10); color: mocha.subtext0; width: parent.width; elide: Text.ElideRight }
                                    }
                                }
                            }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: barWindow.width < 1920 ? barWindow.s(4) : barWindow.s(8)
                                Item { width: barWindow.s(24); height: barWindow.s(24); anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        anchors.centerIn: parent; text: "󰒮"
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(26)
                                        color: prevMouse.containsMouse ? mocha.text : mocha.overlay2
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        scale: prevMouse.containsMouse ? 1.1 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                                    }
                                    MouseArea { id: prevMouse; hoverEnabled: true; anchors.fill: parent; onClicked: { if (barWindow.musicData.playerName === "mpv-pip") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip/pip_ipc.sh", '{"command":["seek","-10"]}']); else Quickshell.execDetached(["playerctl", "previous"]); musicForceRefresh.running = true; } }
                                }
                                Item { width: barWindow.s(28); height: barWindow.s(28); anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        anchors.centerIn: parent
                                        text: barWindow.musicData.status === "Playing" ? "󰏤" : "󰐊"
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(30)
                                        color: playMouse.containsMouse ? mocha.green : mocha.text
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        scale: playMouse.containsMouse ? 1.15 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                                    }
                                    MouseArea { id: playMouse; hoverEnabled: true; anchors.fill: parent; onClicked: { if (barWindow.musicData.playerName === "mpv-pip") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip/pip_ipc.sh", '{"command":["cycle","pause"]}']); else Quickshell.execDetached(["playerctl", "play-pause"]); musicForceRefresh.running = true; } }
                                }
                                Item { width: barWindow.s(24); height: barWindow.s(24); anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        anchors.centerIn: parent; text: "󰒭"
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(26)
                                        color: nextMouse.containsMouse ? mocha.text : mocha.overlay2
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        scale: nextMouse.containsMouse ? 1.1 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                                    }
                                    MouseArea { id: nextMouse; hoverEnabled: true; anchors.fill: parent; onClicked: { if (barWindow.musicData.playerName === "mpv-pip") Quickshell.execDetached(["bash", Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/pip/pip_ipc.sh", '{"command":["seek","10"]}']); else Quickshell.execDetached(["playerctl", "next"]); musicForceRefresh.running = true; } }
                                }
                            }
                        }
                    }
                }

                // ── CENTER BOX: [Apps] [Clock] [Weather] [Matrix] ──
                Rectangle {
                    id: centerBox
                    property bool isHovered: centerMouse.containsMouse
                    color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.95) : Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75)
                    radius: barWindow.s(14); border.width: 1; border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, isHovered ? 0.15 : 0.05)
                    y: (parent.height - barWindow.barHeight) / 2; height: barWindow.barHeight

                    property real targetWidth: centerLayout.implicitWidth + barWindow.s(36)
                    width: targetWidth
                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutExpo } }

                    property real pureCenter: (parent.width - targetWidth) / 2
                    property real minDefaultX: mediaBox.x + mediaBox.targetWidth + (mediaBox.targetWidth > 0 ? barWindow.s(8) : 0)
                    x: Math.max(minDefaultX, pureCenter)
                    Behavior on x { enabled: barWindow.startupCascadeFinished; NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }

                    property bool showLayout: false
                    opacity: showLayout ? 1 : 0
                    transform: Translate {
                        y: centerBox.showLayout ? 0 : barWindow.s(-30)
                        Behavior on y { NumberAnimation { duration: 800; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
                    }
                    Timer { running: barWindow.isStartupReady; interval: 150; onTriggered: centerBox.showLayout = true }
                    Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    scale: isHovered ? 1.03 : 1.0
                    Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutExpo } }
                    Behavior on color { ColorAnimation { duration: 250 } }

                    MouseArea {
                        id: centerMouse; anchors.fill: parent; hoverEnabled: true
                        onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle calendar"])
                    }

                    RowLayout {
                        id: centerLayout; anchors.centerIn: parent; spacing: barWindow.s(16)

                        // Tool hub — left side of the center section (next to the clock).
                        // Opens App Launcher · Useful Tools · Clipboard side-by-side.
                        Rectangle {
                            id: haBtn; property bool isHovered: haMouse.containsMouse
                            color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.6) : "transparent"
                            radius: barWindow.s(10)
                            Layout.preferredWidth: barWindow.s(32); Layout.preferredHeight: barWindow.s(32)
                            Behavior on color { ColorAnimation { duration: 200 } }
                            scale: isHovered ? 1.1 : 1.0; Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                            Text { anchors.centerIn: parent; text: "󰣇"; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(20); color: haBtn.isHovered ? mocha.mauve : mocha.subtext0; Behavior on color { ColorAnimation { duration: 200 } } }
                            MouseArea {
                                id: haMouse; anchors.fill: parent; hoverEnabled: true
                                onClicked: function(mouse) {
                                    mouse.accepted = true;
                                    Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle toolhub"]);
                                }
                            }
                        }

                        // Clock
                        Item {
                            Layout.preferredWidth: clockCol.implicitWidth
                            Layout.preferredHeight: clockCol.implicitHeight
                            ColumnLayout {
                                id: clockCol; anchors.fill: parent
                                spacing: -2
                                Text { text: barWindow.timeStr; Layout.alignment: Qt.AlignHCenter; font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(16); font.weight: Font.Black; color: mocha.blue }
                                Text { text: barWindow.dateStr; Layout.alignment: Qt.AlignHCenter; font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(11); font.weight: Font.Bold; color: mocha.subtext0 }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle calendar"]) }
                        }

                        // Weather
                        Item {
                            Layout.preferredWidth: weatherRow.implicitWidth
                            Layout.preferredHeight: weatherRow.implicitHeight
                            RowLayout {
                                id: weatherRow; anchors.fill: parent
                                spacing: barWindow.s(8)
                                Text { text: barWindow.weatherIcon; Layout.alignment: Qt.AlignVCenter; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(24); color: Qt.tint(barWindow.weatherHex, Qt.rgba(mocha.mauve.r, mocha.mauve.g, mocha.mauve.b, 0.4)) }
                                Text { text: barWindow.weatherTemp; Layout.alignment: Qt.AlignVCenter; font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(17); font.weight: Font.Black; color: mocha.peach }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle calendar"]) }
                        }

                        // Home Assistant dashboard (was Matrix's slot)
                        Rectangle {
                            id: matrixBtn; property bool isHovered: matrixMouse.containsMouse
                            color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.6) : "transparent"
                            radius: barWindow.s(10)
                            Layout.preferredWidth: barWindow.s(32); Layout.preferredHeight: barWindow.s(32)
                            Behavior on color { ColorAnimation { duration: 200 } }
                            scale: isHovered ? 1.1 : 1.0; Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                            Text { anchors.centerIn: parent; text: "󰟐"; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(20); color: matrixBtn.isHovered ? mocha.mauve : mocha.subtext0; Behavior on color { ColorAnimation { duration: 200 } } }
                            MouseArea { id: matrixMouse; anchors.fill: parent; hoverEnabled: true; onClicked: function(m) { m.accepted = true; Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle homeassistant"]); } }
                        }
                    }
                }

                // ── RIGHT CONTENT ──
                Row {
                    id: rightContent
                    anchors.right: parent.right
                    y: (parent.height - barWindow.barHeight) / 2
                    spacing: barWindow.s(4)
                    property bool showLayout: false
                    opacity: showLayout ? 1 : 0
                    transform: Translate {
                        x: rightContent.showLayout ? 0 : barWindow.s(30)
                        Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
                    }
                    Timer { running: barWindow.isStartupReady && barWindow.isDataReady; interval: 250; onTriggered: rightContent.showLayout = true }
                    Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }


                    // System tray
                    Rectangle {
                        height: barWindow.barHeight; radius: barWindow.s(14)
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.08); border.width: 1
                        color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75); anchors.verticalCenter: parent.verticalCenter
                        property real targetWidth: trayRow.implicitWidth > 1 ? trayRow.implicitWidth + barWindow.s(24) : 0
                        width: targetWidth; Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutExpo } }
                        visible: targetWidth > 0; opacity: targetWidth > 0 ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 300 } }

                        Row {
                            id: trayRow; anchors.centerIn: parent; spacing: barWindow.s(10)
                            Repeater {
                                id: trayRepeater; model: SystemTray.items
                                delegate: Image {
                                    id: trayIcon; source: modelData.icon || ""; fillMode: Image.PreserveAspectFit
                                    // Hidden via middle-click (persisted); Steam only shows in gaming mode.
                                    visible: barWindow.trayShouldShow(modelData)
                                    sourceSize: Qt.size(barWindow.s(18), barWindow.s(18)); width: barWindow.s(18); height: barWindow.s(18); anchors.verticalCenter: parent.verticalCenter
                                    property bool isHovered: trayMouse.containsMouse
                                    property bool initAnimTrigger: false
                                    opacity: initAnimTrigger ? (isHovered ? 1.0 : 0.8) : 0.0
                                    scale: initAnimTrigger ? (isHovered ? 1.15 : 1.0) : 0.0
                                    Component.onCompleted: { if (!barWindow.startupCascadeFinished) { trayTimer.interval = index * 50; trayTimer.start(); } else { initAnimTrigger = true; } }
                                    Timer { id: trayTimer; running: false; repeat: false; onTriggered: trayIcon.initAnimTrigger = true }
                                    Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                                    Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutBack } }
                                    QsMenuAnchor { id: trayMenu; anchor.window: barWindow; anchor.item: trayIcon; menu: modelData.menu }
                                    MouseArea {
                                        id: trayMouse; anchors.fill: parent; hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                        onClicked: function(m) {
                                            if (m.button === Qt.LeftButton) {
                                                if (modelData.isMenuOnly || modelData.onlyMenu) trayMenu.open();
                                                else if (typeof modelData.activate === "function") modelData.activate();
                                            } else if (m.button === Qt.MiddleButton) {
                                                barWindow.trayToggleHide(modelData);   // hide this icon
                                            } else {
                                                if (modelData.menu) trayMenu.open();
                                                else if (typeof modelData.contextMenu === "function") modelData.contextMenu(m.x, m.y);
                                                else modelData.activate();
                                            }
                                        }
                                    }
                                }
                            }
                            // Overflow arrow — pinned to the RIGHT of the tray icons.
                            // Only shown when icons are hidden; click toggles the drawer.
                            // Default glyph points left (toward the icons it reveals); flips when open.
                            Rectangle {
                                visible: barWindow.trayHidden.length > 0
                                width: visible ? barWindow.s(16) : 0; height: barWindow.s(18)
                                anchors.verticalCenter: parent.verticalCenter
                                radius: barWindow.s(6)
                                color: arrowMa.containsMouse ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.7) : "transparent"
                                Text {
                                    anchors.centerIn: parent; text: "󰅁"
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(13)
                                    color: arrowMa.containsMouse ? mocha.text : mocha.overlay1
                                    rotation: barWindow.trayExpanded ? 180 : 0
                                    Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                }
                                MouseArea { id: arrowMa; anchors.fill: parent; hoverEnabled: true; onClicked: barWindow.trayExpanded = !barWindow.trayExpanded }
                            }
                        }
                    }

                    // System pills
                    Rectangle {
                        height: barWindow.barHeight; radius: barWindow.s(14)
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.08); border.width: 1
                        color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75); anchors.verticalCenter: parent.verticalCenter; clip: true
                        property real targetWidth: sysRow.width + barWindow.s(20)
                        width: targetWidth; Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutQuint } }

                        Row {
                            id: sysRow; anchors.centerIn: parent; spacing: barWindow.s(8)
                            property int pillH: barWindow.s(34)

                            // ── Workspace pills (compact, merged into sys row) ──
                            Repeater {
                                model: barWindow.workspaceCount
                                delegate: Rectangle {
                                    id: wsPill
                                    property bool isHovered: wsMouse.containsMouse
                                    property string wsName: String(index + 1)
                                    // Reference the Hyprland state directly so this rebinds on
                                    // workspace switch / window changes (dependency-through-function
                                    // isn't tracked).
                                    // hyprTick + focusedWorkspace passed as args so this tracks
                                    // them (reads inside wsStateFor wouldn't be tracked).
                                    property string stateLabel: barWindow.wsStateFor(index + 1, barWindow.hyprTick, Hyprland.focusedWorkspace)
                                    width: barWindow.s(28); height: sysRow.pillH
                                    radius: barWindow.s(8)
                                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                                    // Active = mocha.blue to match the clock numbers in the
                                    // calendar module. Inactive backgrounds kept airy —
                                    // the bold kanji carries the state, not the fill.
                                    color: stateLabel === "active" ? mocha.blue
                                         : (isHovered ? Qt.rgba(mocha.overlay0.r, mocha.overlay0.g, mocha.overlay0.b, 0.45)
                                         : (stateLabel === "occupied" ? Qt.rgba(mocha.surface2.r, mocha.surface2.g, mocha.surface2.b, 0.40)
                                         : Qt.rgba(mocha.surface0.r, mocha.surface0.g, mocha.surface0.b, 0.18)))
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                    scale: isHovered && stateLabel !== "active" ? 1.08 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                                    // Hover → preview the windows on this workspace, reusing the
                                    // dock's ScreencopyView preview popup.
                                    Timer {
                                        id: wsPreviewHoverTimer; interval: 400; repeat: false
                                        running: wsPill.isHovered
                                        onTriggered: {
                                            if (!wsPill.isHovered) return;
                                            // map to scene (window) coords — barWindow is a Window, not an Item.
                                            barWindow.previewWsX = wsPill.mapToItem(null, wsPill.width / 2, 0).x;
                                            barWindow.previewDockIndex = -1;
                                            barWindow.previewWsId = index + 1;
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        text: barWindow.toKanji(wsName)
                                        font.family: "Noto Sans CJK JP"; font.pixelSize: barWindow.s(13)
                                        font.weight: Font.Black
                                        // Empty workspaces use subtext0, not overlay0 — the
                                        // palette remap made overlay0 a dark grey that read
                                        // as disabled.
                                        color: stateLabel === "active" ? mocha.crust
                                             : (isHovered ? mocha.text : (stateLabel === "occupied" ? mocha.text : mocha.subtext0))
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }
                                    MouseArea {
                                        id: wsMouse; hoverEnabled: true; anchors.fill: parent
                                        onClicked: {
                                            // Validate — Hyprland workspace names *should* be alphanumeric,
                                            // but a malicious config could include shell metacharacters
                                            if (/^[A-Za-z0-9_\-]+$/.test(wsName)) {
                                                Quickshell.execDetached(["sh", "-c",
                                                    "$HOME/.config/hypr/scripts/qs_manager.sh \"$1\"",
                                                    "_", wsName]);
                                            } else {
                                                console.warn("Refused unsafe workspace name:", wsName);
                                            }
                                        }
                                    }
                                }
                            }

                            // Thin divider between workspaces and system pills
                            Rectangle {
                                width: 1; height: sysRow.pillH - barWindow.s(8)
                                anchors.verticalCenter: parent.verticalCenter
                                color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.12)
                            }

                            // (Float toggle moved into the utility group next to the
                            //  notification bell — shared background per user request.)

                            // KB layout
                            Rectangle {
                                id: kbPill; property bool isHovered: kbMouse.containsMouse
                                color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.6) : Qt.rgba(mocha.surface0.r, mocha.surface0.g, mocha.surface0.b, 0.4)
                                radius: barWindow.s(10); height: sysRow.pillH; clip: true
                                Behavior on color { ColorAnimation { duration: 200 } }
                                property real targetWidth: kbRow.width + barWindow.s(24); width: targetWidth
                                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutQuint } }
                                scale: isHovered ? 1.05 : 1.0; Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                                property bool kbInitAnim: false
                                Timer { running: rightContent.showLayout && !kbPill.kbInitAnim; interval: 50; onTriggered: kbPill.kbInitAnim = true }
                                opacity: kbInitAnim ? 1 : 0
                                transform: Translate { y: kbPill.kbInitAnim ? 0 : barWindow.s(15); Behavior on y { NumberAnimation { duration: 500; easing.type: Easing.OutBack } } }
                                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                Row {
                                    id: kbRow; anchors.centerIn: parent; spacing: barWindow.s(8)
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "󰌌"; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(16); color: kbPill.isHovered ? mocha.text : mocha.overlay2 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: barWindow.kbLayout; font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(13); font.weight: Font.Black; color: mocha.text }
                                }
                                MouseArea {
                                    id: kbMouse; anchors.fill: parent; hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: function(mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            // Right-click: switch language between English and Japanese —
                                            // input method for all windows (fcitx5) + the LANG/LANGUAGE env
                                            // for newly launched apps. No system-wide locale / root / relogin.
                                            // Run it through kbAction, then re-read the real input mode so
                                            // the pill settles event-driven (slightly longer settle for the
                                            // heavier script). Action output is silenced so only kb_fetch
                                            // (the last line) sets the label.
                                            kbAction.running = false;
                                            kbAction.command = ["bash", "-c",
                                                "\"$HOME/.config/hypr/scripts/set_system_language.sh\" >/dev/null 2>&1; " +
                                                "sleep 0.15; ~/.config/hypr/scripts/quickshell/watchers/kb_fetch.sh"];
                                            kbAction.running = true;
                                        } else {
                                            // Left-click: optimistically flip the label so it feels instant,
                                            // then toggle Mozc and re-read the true state through kbAction —
                                            // no poll loop, the update is driven entirely by this click.
                                            barWindow.kbLayout = (barWindow.kbLayout === "JP" ? "EN" : "JP");
                                            kbAction.running = false;
                                            kbAction.command = ["bash", "-c",
                                                "fcitx5-remote -t >/dev/null 2>&1; " +
                                                "sleep 0.10; ~/.config/hypr/scripts/quickshell/watchers/kb_fetch.sh"];
                                            kbAction.running = true;
                                        }
                                    }
                                }
                            }

                            // WiFi / Ethernet
                            Rectangle {
                                id: wifiPill; property bool isHovered: wifiMouse.containsMouse
                                radius: barWindow.s(10); height: sysRow.pillH
                                color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.6) : Qt.rgba(mocha.surface0.r, mocha.surface0.g, mocha.surface0.b, 0.4); clip: true
                                Rectangle {
                                    anchors.fill: parent; radius: barWindow.s(10)
                                    opacity: barWindow.showEthernet ? (barWindow.ethStatus === "Connected" ? 1.0 : 0.0) : (barWindow.isWifiOn ? 1.0 : 0.0)
                                    Behavior on opacity { NumberAnimation { duration: 300 } }
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: mocha.blue }
                                        GradientStop { position: 1.0; color: Qt.lighter(mocha.blue, 1.3) }
                                    }
                                }
                                property real targetWidth: wifiRow.width + barWindow.s(24); width: targetWidth
                                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutQuint } }
                                scale: isHovered ? 1.05 : 1.0; Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                                Behavior on color { ColorAnimation { duration: 200 } }
                                property bool wifiInitAnim: false
                                Timer { running: rightContent.showLayout && !wifiPill.wifiInitAnim; interval: 100; onTriggered: wifiPill.wifiInitAnim = true }
                                opacity: wifiInitAnim ? 1 : 0
                                transform: Translate { y: wifiPill.wifiInitAnim ? 0 : barWindow.s(15); Behavior on y { NumberAnimation { duration: 500; easing.type: Easing.OutBack } } }
                                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                Row {
                                    id: wifiRow; anchors.centerIn: parent; spacing: barWindow.s(8)
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: barWindow.showEthernet ? "󰈀" : barWindow.wifiIcon; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(16); color: barWindow.showEthernet ? (barWindow.ethStatus === "Connected" ? mocha.base : mocha.subtext0) : (barWindow.isWifiOn ? mocha.base : mocha.subtext0) }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: barWindow.showEthernet ? barWindow.ethStatus : (barWindow.isWifiOn ? (barWindow.wifiSsid !== "" ? barWindow.wifiSsid : "On") : "Off"); textFormat: Text.PlainText; visible: text !== ""; font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(13); font.weight: Font.Black; color: barWindow.showEthernet ? (barWindow.ethStatus === "Connected" ? mocha.base : mocha.text) : (barWindow.isWifiOn ? mocha.base : mocha.text); width: Math.min(implicitWidth, barWindow.s(100)); elide: Text.ElideRight }
                                }
                                MouseArea { id: wifiMouse; hoverEnabled: true; anchors.fill: parent; onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle network wifi"]) }
                            }

                            // Bluetooth
                            Rectangle {
                                id: btPill; property bool isHovered: btMouse.containsMouse
                                radius: barWindow.s(10); height: sysRow.pillH; clip: true
                                color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.6) : Qt.rgba(mocha.surface0.r, mocha.surface0.g, mocha.surface0.b, 0.4)
                                Rectangle {
                                    anchors.fill: parent; radius: barWindow.s(10)
                                    opacity: barWindow.isBtOn ? 1.0 : 0.0; Behavior on opacity { NumberAnimation { duration: 300 } }
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: mocha.mauve }
                                        GradientStop { position: 1.0; color: Qt.lighter(mocha.mauve, 1.3) }
                                    }
                                }
                                property real targetWidth: barWindow.isDesktop ? 0 : btRow.width + barWindow.s(24)
                                width: targetWidth; visible: targetWidth > 0; Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutQuint } }
                                scale: isHovered ? 1.05 : 1.0; Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                                Behavior on color { ColorAnimation { duration: 200 } }
                                property bool btInitAnim: false
                                Timer { running: rightContent.showLayout && !btPill.btInitAnim; interval: 150; onTriggered: btPill.btInitAnim = true }
                                opacity: btInitAnim ? 1 : 0
                                transform: Translate { y: btPill.btInitAnim ? 0 : barWindow.s(15); Behavior on y { NumberAnimation { duration: 500; easing.type: Easing.OutBack } } }
                                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                Row {
                                    id: btRow; anchors.centerIn: parent; spacing: barWindow.s(8)
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: barWindow.btIcon; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(16); color: barWindow.isBtOn ? mocha.base : mocha.subtext0 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: barWindow.btDevice; textFormat: Text.PlainText; visible: text !== ""; font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(13); font.weight: Font.Black; color: barWindow.isBtOn ? mocha.base : mocha.text; width: Math.min(implicitWidth, barWindow.s(100)); elide: Text.ElideRight }
                                }
                                MouseArea { id: btMouse; hoverEnabled: true; anchors.fill: parent; onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle network bt"]) }
                            }

                            // (Matrix pill moved into the utility group next to the
                            //  notification bell — shared background per user request.)

}
                    }

                    // Utility group — floating panel (notes) · matrix · notification
                    // bell share ONE background pill, same style as the AI button.
                    Rectangle {
                        id: bellPill
                        color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75)
                        radius: barWindow.s(14); border.width: 1
                        border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.05)
                        height: barWindow.barHeight
                        width: utilRow.width + barWindow.s(16)
                        anchors.verticalCenter: parent.verticalCenter

                        property bool bellInitAnim: false
                        Timer { running: rightContent.showLayout && !bellPill.bellInitAnim; interval: 280; onTriggered: bellPill.bellInitAnim = true }
                        opacity: bellInitAnim ? 1 : 0
                        transform: Translate {
                            x: bellPill.bellInitAnim ? 0 : barWindow.s(30)
                            Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
                        }
                        Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

                        Row {
                            id: utilRow
                            anchors.centerIn: parent
                            spacing: barWindow.s(2)

                            // Float toggle — floats/tiles every window on the active
                            // workspace (moved here from the system-pills row).
                            Rectangle {
                                width: barWindow.s(36); height: barWindow.s(36); radius: barWindow.s(10)
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                property bool isFloating: barWindow.workspaceIsFloating
                                color: floatMa.containsMouse && !isFloating ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.9) : "transparent"
                                Behavior on color { ColorAnimation { duration: 200 } }

                                Rectangle {
                                    anchors.fill: parent; radius: parent.radius
                                    opacity: parent.isFloating ? 1.0 : 0.0
                                    Behavior on opacity { NumberAnimation { duration: 250 } }
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: mocha.mauve }
                                        GradientStop { position: 1.0; color: Qt.lighter(mocha.mauve, 1.3) }
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    text: parent.isFloating ? "󰒱" : "󰕰"
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(18)
                                    color: parent.isFloating ? mocha.base : (floatMa.containsMouse ? mocha.mauve : mocha.subtext0)
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                MouseArea {
                                    id: floatMa; anchors.fill: parent; hoverEnabled: true
                                    // Reads LIVE hyprctl state to decide direction (QML's cached
                                    // floating flag lags a frame — see float_toggle.sh).
                                    onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/float_toggle.sh"])
                                }
                            }

                            // Matrix chat (Element overlay, top-right popup)
                            Rectangle {
                                width: barWindow.s(36); height: barWindow.s(36); radius: barWindow.s(10)
                                anchors.verticalCenter: parent.verticalCenter
                                color: matrixMa.containsMouse ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.9) : "transparent"
                                Behavior on color { ColorAnimation { duration: 200 } }
                                Text {
                                    anchors.centerIn: parent; text: "󰮼"
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(19)
                                    color: matrixMa.containsMouse ? mocha.green : mocha.subtext0
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                MouseArea {
                                    id: matrixMa; anchors.fill: parent; hoverEnabled: true
                                    onClicked: Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/qs_manager.sh toggle matrix"])
                                }
                            }

                            // Notification bell → battery popup
                            Rectangle {
                                width: barWindow.s(36); height: barWindow.s(36); radius: barWindow.s(10)
                                anchors.verticalCenter: parent.verticalCenter
                                color: bellMouse.containsMouse ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.9) : "transparent"
                                Behavior on color { ColorAnimation { duration: 200 } }
                                Text {
                                    anchors.centerIn: parent; text: "󰂚"
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(22)
                                    color: bellMouse.containsMouse ? mocha.green : mocha.subtext0
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                // Notification dot
                                Rectangle {
                                    visible: barWindow.hasNotifications
                                    width: barWindow.s(8); height: barWindow.s(8)
                                    radius: barWindow.s(4)
                                    color: mocha.red
                                    anchors.right: parent.right; anchors.top: parent.top
                                    anchors.rightMargin: barWindow.s(2); anchors.topMargin: barWindow.s(2)

                                    SequentialAnimation on scale {
                                        running: barWindow.hasNotifications
                                        loops: 3
                                        NumberAnimation { to: 1.4; duration: 300; easing.type: Easing.OutBack }
                                        NumberAnimation { to: 1.0; duration: 300; easing.type: Easing.InOutSine }
                                    }
                                }
                                MouseArea {
                                    id: bellMouse; anchors.fill: parent; hoverEnabled: true
                                    onClicked: {
                                        barWindow.hasNotifications = false;
                                        Quickshell.execDetached(["bash", "-c", "echo 0 > /tmp/qs_bell_dot; ~/.config/hypr/scripts/qs_manager.sh toggle battery"]);
                                    }
                                }
                            }
                        }
                    }

                    // Recording indicator
                    Rectangle {
                        id: recButton; property bool isHovered: recMouse.containsMouse
                        color: isHovered ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.95) : Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.75)
                        radius: barWindow.s(14); border.width: 1; border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, isHovered ? 0.15 : 0.05)
                        property real targetWidth: barWindow.isRecording ? barWindow.barHeight : 0
                        width: targetWidth; height: barWindow.barHeight; anchors.verticalCenter: parent.verticalCenter
                        visible: targetWidth > 0 || opacity > 0; opacity: barWindow.isRecording ? 1.0 : 0.0; clip: true
                        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }
                        Behavior on opacity { NumberAnimation { duration: 300 } }
                        scale: isHovered ? 1.05 : 1.0; Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutExpo } }
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Text {
                            anchors.centerIn: parent; text: ""; font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(20); color: mocha.red
                            SequentialAnimation on opacity {
                                running: barWindow.isRecording && !recButton.isHovered; loops: Animation.Infinite
                                NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                            }
                            SequentialAnimation on scale {
                                running: barWindow.isRecording && !recButton.isHovered; loops: Animation.Infinite
                                NumberAnimation { to: 1.15; duration: 600; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0;  duration: 600; easing.type: Easing.InOutSine }
                            }
                        }
                        MouseArea { id: recMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { barWindow.isRecording = false; Quickshell.execDetached(["bash", "-c", "~/.config/hypr/scripts/screenshot.sh"]); } }
                    }
                }
            }
        // Grace period so moving the cursor from the dock icon onto the preview (to
        // hit an X) doesn't dismiss it. Cancelled while the icon or popup is hovered.
        Timer { id: previewHideTimer; interval: 120; repeat: false; onTriggered: { barWindow.previewDockIndex = -1; barWindow.previewWsId = -1; } }

        // ── Preview PopupWindow ──
        PopupWindow {
            id: previewPopup

            // Source: a hovered dock app OR a hovered workspace pill — both feed the
            // same tiles. Workspace takes priority when its id is set.
            property string hoveredKey: (barWindow.previewDockIndex >= 0 && barWindow.dockItems[barWindow.previewDockIndex])
                ? barWindow.dockKey(barWindow.dockItems[barWindow.previewDockIndex].exec) : ""
            property var tops: barWindow.previewWsId >= 0
                ? barWindow.toplevelsForWorkspace(barWindow.previewWsId, barWindow.hyprTick, Hyprland.toplevels ? Hyprland.toplevels.values : [])
                : barWindow.toplevelsForApp(hoveredKey, barWindow.hyprTick, Hyprland.toplevels ? Hyprland.toplevels.values : [])

            visible: (barWindow.previewDockIndex >= 0 || barWindow.previewWsId >= 0) && tops.length > 0
            anchor.window: barWindow

            readonly property int tileH: barWindow.s(390)
            readonly property int pad: barWindow.s(8)

            implicitWidth:  Math.max(barWindow.s(120), previewTiles.implicitWidth + pad * 2)
            implicitHeight: previewTitle.implicitHeight + tileH + pad * 2 + barWindow.s(6)

            color: "transparent"

            // Centre the popup under the hovered dock icon.
            property real dockStartX: barWindow.barHeight + barWindow.s(4) + barWindow.s(10)
            property real iconStride: barWindow.s(36) + barWindow.s(6)
            property real iconCentreX: barWindow.previewDockIndex < 0 ? 0
                : dockStartX + barWindow.previewDockIndex * iconStride + barWindow.s(18)
            // Workspace pills live on the right, so use the pill's mapped centre there.
            property real centreX: barWindow.previewWsId >= 0 ? barWindow.previewWsX : iconCentreX
            anchor.rect.x: Math.max(barWindow.s(4),
                Math.min(centreX - implicitWidth / 2,
                         barWindow.width - implicitWidth - barWindow.s(4)))
            anchor.rect.y: barWindow.s(8) + barWindow.barHeight + barWindow.s(4)
            anchor.rect.width: 1
            anchor.rect.height: 1

            Rectangle {
                anchors.fill: parent
                radius: barWindow.s(10)
                color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.95)
                border.width: 1
                border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.12)

                // Keep the popup open while the cursor is over it (so you can reach the X).
                HoverHandler {
                    id: previewHover
                    onHoveredChanged: barWindow.refreshPreviewHold()
                }

                Column {
                    anchors.fill: parent
                    anchors.margins: previewPopup.pad
                    spacing: barWindow.s(6)

                    Text {
                        id: previewTitle
                        width: parent.width
                        text: (barWindow.previewWsId >= 0 ? "Workspace " + barWindow.previewWsId : barWindow.previewTitle)
                            + (previewPopup.tops.length > 1 ? "  ·  " + previewPopup.tops.length + " windows" : "")
                        textFormat: Text.PlainText   // app name/class from external windows
                        font.family: "JetBrains Mono"
                        font.pixelSize: barWindow.s(11)
                        font.weight: Font.Bold
                        color: mocha.text
                        elide: Text.ElideRight
                    }

                    // One live, aspect-correct tile per window of the app — captured
                    // directly from the toplevel (works on any workspace, no switching).
                    Row {
                        id: previewTiles
                        height: previewPopup.tileH
                        spacing: barWindow.s(8)

                        Repeater {
                            model: previewPopup.tops
                            delegate: Rectangle {
                                id: tile
                                property var ipc: modelData ? modelData.lastIpcObject : null
                                property bool tileHovered: tileHover.hovered || closeMa.containsMouse
                                // Prefer the live capture size (updates as the window resizes);
                                // fall back to the IPC geometry until the first frame arrives.
                                property real aspect: (scView.sourceSize && scView.sourceSize.height > 0)
                                    ? (scView.sourceSize.width / scView.sourceSize.height)
                                    : ((ipc && ipc.size && ipc.size[1] > 0) ? (ipc.size[0] / ipc.size[1]) : 1.6)
                                height: previewPopup.tileH
                                width: Math.round(height * Math.max(0.3, Math.min(aspect, 3.0)))
                                radius: barWindow.s(6)
                                color: Qt.rgba(mocha.surface0.r, mocha.surface0.g, mocha.surface0.b, 0.8)
                                border.width: 1
                                border.color: tile.tileHovered ? Qt.rgba(mocha.red.r, mocha.red.g, mocha.red.b, 0.6)
                                                               : Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.08)
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                                clip: true

                                ScreencopyView {
                                    id: scView
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    captureSource: modelData ? modelData.wayland : null
                                    live: true
                                    paintCursor: false
                                    // Supersample: render the capture into a 2× offscreen buffer and
                                    // downsample with mipmapping, so downscaled window text stays crisp
                                    // instead of smudging (no change to the on-screen tile size).
                                    smooth: true
                                    layer.enabled: true
                                    layer.smooth: true
                                    layer.mipmap: true
                                    layer.textureSize: Qt.size(Math.max(1, Math.round(width * 2)),
                                                               Math.max(1, Math.round(height * 2)))
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: !scView.hasContent
                                    text: "󰄰"
                                    font.family: "Iosevka Nerd Font"
                                    font.pixelSize: barWindow.s(24)
                                    color: mocha.overlay0
                                }

                                // Tracks hover over the tile (passive — doesn't eat the X's clicks).
                                HoverHandler { id: tileHover }

                                // Close (✕) button — appears on hover, closes this window.
                                Rectangle {
                                    id: closeBtn
                                    visible: tile.tileHovered
                                    anchors.top: parent.top; anchors.right: parent.right
                                    anchors.topMargin: barWindow.s(6); anchors.rightMargin: barWindow.s(6)
                                    width: barWindow.s(24); height: barWindow.s(24); radius: width / 2
                                    color: closeMa.containsMouse ? mocha.red
                                         : Qt.rgba(mocha.crust.r, mocha.crust.g, mocha.crust.b, 0.85)
                                    border.width: 1; border.color: Qt.rgba(mocha.red.r, mocha.red.g, mocha.red.b, 0.7)
                                    scale: closeMa.containsMouse ? 1.12 : 1.0
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }
                                    Text {
                                        anchors.centerIn: parent; text: ""
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: barWindow.s(13)
                                        color: closeMa.containsMouse ? mocha.crust : mocha.red
                                    }
                                    MouseArea {
                                        id: closeMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (tile.ipc && tile.ipc.address)
                                                Hyprland.dispatch("closewindow address:" + tile.ipc.address);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Dock right-click menu — a real popup window so it isn't clipped by the
        //    narrow bar; HyprlandFocusGrab closes it when you click away. ──
        PopupWindow {
            id: dockMenuPopup
            visible: barWindow.dockMenuOpen
            anchor.window: barWindow
            color: "transparent"

            readonly property var rows: [
                { label: barWindow.dockIsPinned(barWindow.dockMenuExec) ? "Remove from Dock" : "Add to Dock", act: "pin", on: true },
                { label: (barWindow.dockGaming.indexOf(barWindow.dockKey(barWindow.dockMenuExec)) >= 0) ? "Unassign from Gaming" : "Assign to Gaming (only)", act: "gaming", on: true },
                { label: (barWindow.dockStudyRemoved.indexOf(barWindow.dockKey(barWindow.dockMenuExec)) >= 0) ? "Restore to Study" : "Remove from Study", act: "study", on: true },
                { label: "Close window", act: "close", on: barWindow.clientsForApp([barWindow.dockKey(barWindow.dockMenuExec)], barWindow.hyprClients).length > 0 }
            ]
            readonly property int rowH: barWindow.s(32)
            implicitWidth:  barWindow.s(220)
            implicitHeight: rows.length * rowH + barWindow.s(12)

            property real iconStride: barWindow.s(36) + barWindow.s(6)
            property real dockStartX: barWindow.barHeight + barWindow.s(4) + barWindow.s(10)
            property real iconCentreX: barWindow.dockMenuIndex < 0 ? 0
                : dockStartX + barWindow.dockMenuIndex * iconStride + barWindow.s(18)
            anchor.rect.x: Math.max(barWindow.s(4),
                Math.min(iconCentreX - implicitWidth / 2,
                         barWindow.width - implicitWidth - barWindow.s(4)))
            anchor.rect.y: barWindow.s(8) + barWindow.barHeight + barWindow.s(4)
            anchor.rect.width: 1
            anchor.rect.height: 1

            HyprlandFocusGrab {
                windows: [dockMenuPopup]
                active: barWindow.dockMenuOpen
                onCleared: barWindow.dockMenuOpen = false
            }

            Rectangle {
                anchors.fill: parent
                radius: barWindow.s(12)
                color: Qt.rgba(mocha.base.r, mocha.base.g, mocha.base.b, 0.97)
                border.width: 1
                border.color: Qt.rgba(mocha.text.r, mocha.text.g, mocha.text.b, 0.12)

                Column {
                    anchors.fill: parent
                    anchors.margins: barWindow.s(6)
                    spacing: 0
                    Repeater {
                        model: dockMenuPopup.rows
                        delegate: Rectangle {
                            width: parent.width
                            height: modelData.on ? dockMenuPopup.rowH : 0
                            visible: modelData.on
                            radius: barWindow.s(8)
                            color: rowMa.containsMouse ? Qt.rgba(mocha.surface1.r, mocha.surface1.g, mocha.surface1.b, 0.85) : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left; anchors.leftMargin: barWindow.s(12)
                                text: modelData.label
                                font.family: "JetBrains Mono"; font.pixelSize: barWindow.s(12)
                                color: mocha.text
                            }
                            MouseArea {
                                id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { barWindow.dockMenuAction(modelData.act); barWindow.dockMenuOpen = false; }
                            }
                        }
                    }
                }
            }
        }

        }
    }
}
