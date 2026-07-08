import QtQuick
import "WindowRegistry.js" as LayoutMath

// Per-widget scale helper. The global uiScale comes from the ScaleStore
// singleton (one settings.json watch per engine) — this used to run a cat
// Process + inotifywait waiter PER INSTANCE.
Item {
    id: root
    visible: false

    property real currentWidth: 1920.0
    property real currentHeight: 1080.0
    property real uiScale: ScaleStore.uiScale

    // Passes both Width and Height to respect aspect ratio
    property real baseScale: LayoutMath.getScale(currentWidth, currentHeight, uiScale)

    function s(val) {
        return LayoutMath.s(val, baseScale);
    }
}
