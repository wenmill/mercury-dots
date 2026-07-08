pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Single source of truth for the matugen palette. Watches qs_colors.json
// in-process (FileView — no subprocess, no polling); every MatugenColors
// instance just aliases these properties. Before this existed, each of the
// ~20 MatugenColors instances ran its own 1-second `cat` fork poll: 20
// process spawns per second, 24/7, all reading the same file.
Item {
    id: store

    property color base: "#1e1e2e"
    property color mantle: "#181825"
    property color crust: "#11111b"
    property color text: "#cdd6f4"
    property color subtext0: "#a6adc8"
    property color subtext1: "#bac2de"
    property color surface0: "#313244"
    property color surface1: "#45475a"
    property color surface2: "#585b70"
    property color overlay0: "#6c7086"
    property color overlay1: "#7f849c"
    property color overlay2: "#9399b2"
    property color blue: "#89b4fa"
    property color sapphire: "#74c7ec"
    property color peach: "#fab387"
    property color green: "#a6e3a1"
    property color red: "#f38ba8"
    property color mauve: "#cba6f7"
    property color pink: "#f5c2e7"
    property color yellow: "#f9e2af"
    property color maroon: "#eba0ac"
    property color teal: "#94e2d5"

    property string rawJson: ""

    readonly property var _keys: [
        "base", "mantle", "crust", "text", "subtext0", "subtext1",
        "surface0", "surface1", "surface2", "overlay0", "overlay1", "overlay2",
        "blue", "sapphire", "peach", "green", "red", "mauve",
        "pink", "yellow", "maroon", "teal"
    ]

    function _apply(txt) {
        txt = (txt || "").trim();
        if (txt === "" || txt === rawJson) return;
        rawJson = txt;
        try {
            let c = JSON.parse(txt);
            for (let i = 0; i < _keys.length; i++)
                if (c[_keys[i]]) store[_keys[i]] = c[_keys[i]];
        } catch (e) {}
    }

    FileView {
        path: Quickshell.env("HOME") + "/.config/hypr/scripts/quickshell/qs_colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: store._apply(text())
    }
}
