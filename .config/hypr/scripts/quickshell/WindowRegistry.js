.pragma library

function getScale(mw, mh, userScale) {
    if (arguments.length === 2) {
        userScale = mh;
        mh = mw * (1080.0 / 1920.0);
    }

    if (mw <= 0 || mh <= 0) return 1.0;

    let rw = mw / 1920.0;
    let rh = mh / 1080.0;
    let r = Math.min(rw, rh);

    let baseScale = 1.0;

    if (r <= 1.0) {
        baseScale = Math.max(0.35, Math.pow(r, 0.85));
    } else {
        baseScale = Math.pow(r, 0.5);
    }

    return baseScale * (userScale !== undefined ? userScale : 1.0);
}

function s(val, scale) {
    return Math.round(val * scale);
}

// One builder per window so getLayout only computes the entry it was asked
// for — the old version built the whole 14-entry table (~44 s() calls and an
// object per entry) on every lookup. Numbers are unchanged.
var _layouts = {
    // --- Top Row Popups ---
    "battery":   function(mw, mh, sc) { return { w: s(801, sc), h: s(760, sc), rx: mw - s(805, sc), ry: s(60, sc), comp: "battery/BatteryPopup.qml" }; },
    "network":   function(mw, mh, sc) { return { w: s(900, sc), h: s(700, sc), rx: mw - s(904, sc), ry: s(60, sc), comp: "network/NetworkPopup.qml" }; },
    // "Hermes' Notebook" — a da Vinci anatomical-codex page visualizing what
    // Hermes has learned about you (~/.hermes/memories/USER.md). Same
    // footprint as battery — a top-row popup.
    "charactersheet": function(mw, mh, sc) { return { w: s(801, sc), h: s(760, sc), rx: s(16, sc), ry: s(60, sc), comp: "charactersheet/CharacterSheet.qml" }; },
    "music":     function(mw, mh, sc) { return { w: s(700, sc), h: s(650, sc), rx: s(5, sc), ry: s(60, sc), comp: "music/MusicPopup.qml" }; },

    // --- Central tool hub: App Launcher · Useful Tools · Clipboard in ONE popup ---
    // The standalone applauncher/tools/clipboard windows — and the distractions
    // "library" (chess/Kavita) page — were consolidated into toolhub/ and the old
    // dirs removed. All their triggers (Super+C, Super+D, the bar buttons) open
    // this hub now; the three components live in toolhub/ and load via its Loaders.
    "toolhub":     function(mw, mh, sc) { return { w: s(1450, sc), h: s(510, sc), rx: Math.floor((mw/2)-(s(1450, sc)/2)), ry: s(60, sc), comp: "toolhub/ToolHub.qml" }; },
    "focuswarn":   function(mw, mh, sc) { return { w: s(340, sc), h: s(180, sc), rx: Math.floor((mw/2)-(s(340, sc)/2)), ry: Math.floor((mh/2)-(s(180, sc)/2)), comp: "FocusWarning.qml" }; },
    "gamingprompt":function(mw, mh, sc) { return { w: s(360, sc), h: s(280, sc), rx: Math.floor((mw/2)-(s(360, sc)/2)), ry: Math.floor((mh/2)-(s(280, sc)/2)), comp: "GamingPrompt.qml" }; },

    // --- Large / Centered Tools ---
    "focustime": function(mw, mh, sc) { return { w: s(900, sc), h: s(700, sc), rx: Math.floor((mw/2)-(s(900, sc)/2)), ry: Math.floor((mh/2)-(s(700, sc)/2)), comp: "focustime/FocusTimePopup.qml" }; },
    "guide":     function(mw, mh, sc) { return { w: s(1200, sc), h: s(750, sc), rx: Math.floor((mw/2)-(s(1200, sc)/2)), ry: Math.floor((mh/2)-(s(750, sc)/2)), comp: "guide/GuidePopup.qml" }; },
    "calendar":  function(mw, mh, sc) { return { w: s(1450, sc), h: s(750, sc), rx: Math.floor((mw/2)-(s(1450, sc)/2)), ry: s(60, sc), comp: "calendar/CalendarPopup.qml" }; },
    "wallpaper": function(mw, mh, sc) { return { w: mw, h: s(650, sc), rx: 0, ry: Math.floor((mh/2)-(s(650, sc)/2)), comp: "wallpaper/WallpaperPicker.qml" }; },

    "movies":    function(mw, mh, sc) { return { w: s(1370, sc), h: s(850, sc), rx: Math.floor((mw/2)-(s(1370, sc)/2)), ry: mh - s(850, sc), comp: "movies/MovieWidget.qml" }; },

    // --- Panels ---
    "settings":  function(mw, mh, sc) { return { w: s(450, sc), h: mh, rx: 0, ry: 0, comp: "settings/SettingsPopup.qml" }; },

    // --- Utility ---
    "hidden":    function(mw, mh, sc) { return { w: 1, h: 1, rx: -5000, ry: -5000, comp: "" }; }
};

function getLayout(name, mx, my, mw, mh, userScale) {
    let builder = _layouts[name];
    if (!builder) return null;

    let t = builder(mw, mh, getScale(mw, mh, userScale));
    // "hidden" parks the window at absolute -5000 regardless of monitor origin
    // (the old table encoded this as rx: -5000 - mx).
    if (name === "hidden") {
        t.x = -5000; t.y = -5000;
    } else {
        t.x = mx + t.rx;
        t.y = my + t.ry;
    }
    return t;
}

function getPopupLayout(mw, mh, userScale) {
    if (arguments.length === 2) {
        userScale = mh;
        mh = mw * (1080.0 / 1920.0);
    }

    let scale = getScale(mw, mh, userScale);
    return {
        w: s(350, scale),
        marginTop: s(60, scale),
        marginRight: s(20, scale),
        spacing: s(12, scale),
        radius: s(14, scale),
        padding: s(12, scale)
    };
}
