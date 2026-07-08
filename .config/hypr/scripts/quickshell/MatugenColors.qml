import QtQuick

// Thin per-widget shim over the MatugenStore singleton, kept so the ~20
// existing `MatugenColors { id: _theme }` call sites don't change. The
// singleton owns the qs_colors.json watch (in-process FileView); this used
// to run a 1-second `cat` poll PER INSTANCE.
Item {
    id: root

    readonly property color base:     MatugenStore.base
    readonly property color mantle:   MatugenStore.mantle
    readonly property color crust:    MatugenStore.crust
    readonly property color text:     MatugenStore.text
    readonly property color subtext0: MatugenStore.subtext0
    readonly property color subtext1: MatugenStore.subtext1
    readonly property color surface0: MatugenStore.surface0
    readonly property color surface1: MatugenStore.surface1
    readonly property color surface2: MatugenStore.surface2
    readonly property color overlay0: MatugenStore.overlay0
    readonly property color overlay1: MatugenStore.overlay1
    readonly property color overlay2: MatugenStore.overlay2
    readonly property color blue:     MatugenStore.blue
    readonly property color sapphire: MatugenStore.sapphire
    readonly property color peach:    MatugenStore.peach
    readonly property color green:    MatugenStore.green
    readonly property color red:      MatugenStore.red
    readonly property color mauve:    MatugenStore.mauve
    readonly property color pink:     MatugenStore.pink
    readonly property color yellow:   MatugenStore.yellow
    readonly property color maroon:   MatugenStore.maroon
    readonly property color teal:     MatugenStore.teal

    readonly property string rawJson: MatugenStore.rawJson
}
