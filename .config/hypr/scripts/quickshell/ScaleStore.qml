pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Single in-process watch on settings.json for the global UI scale. All
// Scaler instances (19 declarations) and Main.qml bind to this; each Scaler
// used to run its OWN `cat` Process + bash-c-inotifywait waiter pair — two
// persistent processes per open widget, and the waiter class that orphans
// on shell restarts. FileView spawns nothing and dies with the engine.
Item {
    id: store

    property real uiScale: 1.0

    FileView {
        path: Quickshell.env("HOME") + "/.config/hypr/settings.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                let parsed = JSON.parse(text());
                if (parsed.uiScale !== undefined && store.uiScale !== parsed.uiScale)
                    store.uiScale = parsed.uiScale;
            } catch (e) {}
        }
    }
}
