import QtQuick
import Quickshell

QtObject {
    id: root
    readonly property string home: Quickshell.env("HOME")
    readonly property string xdgRuntimeDir: Quickshell.env("XDG_RUNTIME_DIR")
    
    // Persistent data on disk
    readonly property string cacheDir: home + "/.cache/quickshell"
    readonly property string stateDir: home + "/.local/state/quickshell"
    
    // Ephemeral data in RAM (tmpfs) - fallback to /tmp if XDG_RUNTIME_DIR is somehow empty
    readonly property string runDir: (xdgRuntimeDir !== "" ? xdgRuntimeDir : "/tmp") + "/quickshell"
    readonly property string logDir: runDir + "/logs"

    // mkdir -p is only forked the FIRST time a given path is resolved by this
    // instance; hot callers (e.g. wallpaper thumbnail path building) invoke
    // these per-file, which used to fork a process on every single call.
    property var _ensured: ({})
    function _ensure(envKey, defaultPath) {
        var envPath = Quickshell.env(envKey);
        var finalPath = envPath ? envPath : defaultPath;
        if (!_ensured[finalPath]) {
            _ensured[finalPath] = true;
            Quickshell.execDetached(["mkdir", "-p", finalPath]);
        }
        return finalPath;
    }

    function getCacheDir(widgetName) {
        return _ensure("QS_CACHE_" + widgetName.toUpperCase(), cacheDir + "/" + widgetName);
    }

    function getStateDir(widgetName) {
        return _ensure("QS_STATE_" + widgetName.toUpperCase(), stateDir + "/" + widgetName);
    }

    function getRunDir(widgetName) {
        return _ensure("QS_RUN_" + widgetName.toUpperCase(), runDir + "/" + widgetName);
    }

    function getLogDir(widgetName) {
        return _ensure("QS_LOG_" + widgetName.toUpperCase(), logDir + "/" + widgetName);
    }
}
