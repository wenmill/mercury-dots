//@ pragma UseQApplication
import QtQuick
import Quickshell
import "movies"

ShellRoot {
    Connections {
        target: Quickshell
        function onReloadCompleted() { Quickshell.inhibitReloadPopup() }
        function onReloadFailed(errorString) { Quickshell.inhibitReloadPopup() }
    }

    Main {}
    TopBar {}
    // Movies runs in its own independent overlay window (movies/MoviesWindow.qml)
    // so it coexists with the master shell's popups and the floating window —
    // opening anything else never closes it. Toggled via `ipc call movieswin`.
    MoviesWindow {}
    // The floating panel + web hub is no longer part of this shell. It is now a
    // standalone C++ wlr-layer-shell + WebEngine app (floating/obsidian-shell/)
    // that merges the old Floating.qml edge-peek selector with the Obsidian/
    // Hermes/Dify web views in one window — because Quickshell can't host
    // QtWebEngine in-process. Autostarted from config/overrides.conf; SUPER+O
    // drives it via floating/obsidian-shell.sh.
}

