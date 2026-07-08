// Injection hook for the Home Assistant overlay — currently a NO-OP.
//
// We deliberately do NOT force HA transparent: HA renders inside deeply nested
// web components and derives many surfaces (cards, headers, dialogs) from the
// same background CSS variables, so blanket `background: transparent` overrides
// made cards/headers render wrong ("the background is broken"). HA ships its own
// polished dark theme, so we just let it paint normally. The matugen window
// background only peeks at the 2px rounded corners.
//
// window.QS_COLORS (the live matugen palette) is still injected ahead of this by
// ha_overlay.py, so this stays an easy place to add *targeted, tested* theming
// later (e.g. set a single specific var) without the blanket approach.
(function () {
  /* intentionally empty — stock Home Assistant theme */
})();
