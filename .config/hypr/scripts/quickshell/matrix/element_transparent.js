// Restyle Element to match the desktop, using the same architecture as
// obsidian_transparent.js (the floating panel's transparency injector):
//
//   1) a stylesheet forces backgrounds transparent, zeroes Element's Compound
//      design tokens, and gives floating UI (menus/dialogs/toasts) a solid
//      matugen card so they stay readable over the busy background;
//   2) a JS "definitive backstop" SWEEP reads each element's COMPUTED background
//      and forces it transparent INLINE (inline !important beats any class /
//      compound selector regardless of specificity). This is what actually
//      clears Element's opaque panels — `*{...!important}` cannot, because
//      Element paints them via higher-specificity Compound selectors
//      (e.g. `.cpd-theme-dark .foo`) that outrank the universal rule.
//
// Unlike Obsidian (flat surfaces), Element is full of COLOURED controls — accent
// buttons, avatars, badges, the green primary CTAs. A blanket sweep would strip
// those too, so the sweep is TARGETED: it only clears backgrounds that are dark
// AND near-neutral (the canvas / room-list / timeline surfaces); anything
// saturated or bright (buttons, avatars, accents) keeps its fill.
//
// Both are applied into every Shadow root (Compound renders popovers/toasts in
// shadow DOM) and re-applied incrementally as the SPA mutates.
//
// Colours come from window.QS_COLORS, injected ahead of this file by the Python
// launcher (read live from qs_colors.json — the same palette the bar uses).
(function () {
  var C = window.QS_COLORS || {};
  var surface = C.surface1 || '#252b2c';   // matugen popover/card colour
  var border  = C.surface2 || '#303637';
  var accent  = C.blue     || '#82d3e1';   // matugen accent (selected pills, buttons)
  var accentText = C.crust  || '#0e1415';  // readable text on the accent
  var text    = C.text     || '#dee3e5';

  function hexToRgba(h, a) {
    h = (h || '').replace('#', '');
    if (h.length === 3) h = h.replace(/(.)/g, '$1$1');
    var n = parseInt(h, 16);
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')';
  }
  var panel = hexToRgba(surface, 0.1);     // 10% tint for the room-list / left panel
  var pill  = hexToRgba(surface, 0.16);    // slight bg for the filter pills

  try {
    if (localStorage.getItem('mx_theme') !== 'dark') localStorage.setItem('mx_theme', 'dark');
  } catch (e) {}

  var css =
    // 0) neutralise the Compound/Element background design-tokens. Panels read
    //    `background: var(--cpd-color-bg-*)`, which beats a plain `*` rule — but
    //    zeroing the token wins, and tokens inherit into shadow-DOM components.
    ':root,html,body,.cpd-theme-dark,.cpd-theme-light,#matrixchat{' +
      '--cpd-color-bg-canvas-default:' + panel + '!important;' +
      '--cpd-color-bg-canvas-default-hovered:' + panel + '!important;' +
      '--roomlist-background-color:' + panel + '!important;' +
      '--left-panel-background-color:' + panel + '!important;' +
      '--cpd-color-bg-canvas-disabled:transparent!important;' +
      '--cpd-color-bg-subtle-primary:transparent!important;' +
      '--cpd-color-bg-subtle-secondary:transparent!important;' +
      '--cpd-color-bg-action-secondary-rest:transparent!important;' +
      '--background-color:transparent!important;' +
      '--timeline-background-color:transparent!important;' +
      // accent -> matugen (selected Unreads/People pills, primary buttons, badges)
      '--cpd-color-bg-action-primary-rest:' + accent + '!important;' +
      '--cpd-color-bg-action-primary-hovered:' + accent + '!important;' +
      '--cpd-color-bg-action-primary-pressed:' + accent + '!important;' +
      '--cpd-color-bg-accent-rest:' + accent + '!important;' +
      '--cpd-color-text-action-accent:' + accent + '!important;' +
      '--cpd-color-text-on-solid-primary:' + accentText + '!important;}' +
    // room-list filter pills (Unreads / People / Rooms ...): matugen tint,
    // full accent when selected.
    'button[class*="chat-filter"]{background-color:' + pill + '!important;color:' + text +
      '!important;border-radius:9999px!important;}' +
    'button[class*="chat-filter"][aria-selected="true"]{background-color:' + accent +
      '!important;color:' + accentText + '!important;}' +
    '[class*="roomListPrimaryFilters"] [role="listbox"]{background-color:' + panel + '!important;}' +
    // primary / CTA buttons keep a SOLID accent fill. The universal transparent
    // rule below (and the sweep) would otherwise strip the fill Element applies
    // via a low-specificity rule, leaving the welcome-screen CTAs (Send a Direct
    // Message / Explore Public Rooms / Create a Group Chat) as bare text. These
    // class/attribute selectors outrank the universal `*` rule, so the fill wins.
    // Scoped to the welcome (HomePage) area + the explicit CTA classes so the
    // room-list / nav ICON buttons (compose, settings, threads) stay unfilled —
    // only the actual text CTAs get the accent.
    '.mx_HomePage_button_sendDm,.mx_HomePage_button_explore,.mx_HomePage_button_createGroup,' +
    'button[class*="HomePage_button"],' +
    '.mx_HomePage .mx_AccessibleButton_kind_primary,' +
    '.mx_HomePage button[data-kind="primary"],.mx_HomePage [role="button"][data-kind="primary"]{' +
      'background-color:' + accent + '!important;' +
      'background-image:none!important;' +
      'color:' + accentText + '!important;' +
      'border:none!important;border-radius:8px!important;}' +
    // 1) everything transparent by default
    '*,*::before,*::after{background-color:transparent!important;}' +
    'html,body,#matrixchat{background:transparent!important;background-image:none!important;}' +
    // 2) floating surfaces get a solid matugen card background (kept by the sweep)
    '.mx_ContextualMenu,.mx_IconizedContextMenu,.mx_IconizedContextMenu_optionList,' +
    '.mx_Dialog,.mx_Tooltip,.mx_Tooltip_visible,.mx_Toast_toast,.mx_GenericToast,' +
    '.mx_Toast,.mx_NonUrgentToast,.mx_Menu,' +
    '[role="menu"],[role="dialog"],[role="tooltip"],[role="listbox"],' +
    '.cpd-popover-content,[data-floating-ui-portal]>*{' +
      'background-color:' + surface + '!important;' +
      'border:1px solid ' + border + '!important;' +
      'border-radius:12px!important;}';

  // Floating UI we KEEP as solid matugen cards — the sweep must NOT clear these.
  var KEEP = '.mx_ContextualMenu,.mx_IconizedContextMenu,.mx_IconizedContextMenu_optionList,' +
    '.mx_Dialog,.mx_Tooltip,.mx_Tooltip_visible,.mx_Toast_toast,.mx_GenericToast,' +
    '.mx_Toast,.mx_NonUrgentToast,.mx_Menu,' +
    '[role="menu"],[role="dialog"],[role="tooltip"],[role="listbox"],' +
    '.cpd-popover-content,[data-floating-ui-portal]';

  // The css lives on window so re-injections (bootAssert re-runs this whole file)
  // refresh the palette while the first run's observer keeps working.
  window.__qsElTransCss = css;

  // At DocumentCreation <html> may not exist yet; never append a <style> straight
  // to the document node (it would become the root element and the page renders
  // blank). Use head, else <html>, else (shadow root) the root; null defers.
  function styleHost(root) {
    if (root.nodeType === 9) return root.head || root.documentElement || null;  // Document
    return root.head || root;                                                   // ShadowRoot
  }
  function injectInto(root) {
    var host = styleHost(root); if (!host) return;
    var s = root.querySelector ? root.querySelector('#qs-transparent') : null;
    if (!s) {
      s = document.createElement('style');
      s.id = 'qs-transparent';
      host.appendChild(s);
    }
    if (s.textContent !== window.__qsElTransCss) s.textContent = window.__qsElTransCss;
  }

  // ── The definitive backstop: force opaque SURFACE backgrounds transparent
  //    inline. Only dark, near-neutral colours are cleared (canvas/room-list/
  //    timeline); saturated or bright fills (accent buttons, avatars, badges)
  //    are left alone so the coloured UI survives.
  function isSurfaceBg(bg) {
    // getComputedStyle returns "rgb(r, g, b)" for opaque, "rgba(...)" otherwise —
    // only fully-opaque backgrounds are candidates (our tints have alpha<1).
    var m = /^rgb\((\d+),\s*(\d+),\s*(\d+)\)\s*$/.exec(bg);
    if (!m) return false;
    var r = +m[1], g = +m[2], b = +m[3];
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    return max <= 90 && (max - min) <= 26;   // dark AND near-neutral => a surface
  }
  function sweep(root) {
    var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    // querySelectorAll only returns DESCENDANTS — include the root element itself
    // so an incremental sweep of a mutated element also fixes that element.
    if (root.nodeType === 1) all = [root].concat(Array.prototype.slice.call(all));
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.closest && el.closest(KEEP)) continue;
      var bg;
      try { bg = getComputedStyle(el).backgroundColor; } catch (e) { continue; }
      if (isSurfaceBg(bg)) {
        el.style.setProperty('background-color', 'transparent', 'important');
        el.style.setProperty('background-image', 'none', 'important');
      }
    }
  }

  function walk(node) {
    if (node.shadowRoot) {
      injectInto(node.shadowRoot);
      try { sweep(node.shadowRoot); } catch (e) {}
      node.shadowRoot.querySelectorAll('*').forEach(walk);
    }
  }
  // Re-apply everything for one SUBTREE only (the incremental path).
  function applyTo(root) {
    try { sweep(root); } catch (e) {}
    try { walk(root); root.querySelectorAll('*').forEach(walk); } catch (e) {}
  }
  function apply() {
    injectInto(document);
    try { sweep(document); } catch (e) {}
    document.querySelectorAll('*').forEach(walk);
  }

  // ── Incremental re-apply machinery ──────────────────────────────────────
  // Mutations queue only their own subtree roots (swept individually); a FULL
  // pass runs at boot, on <html>/<body> class changes (theme swap), when roots
  // pile up, or on becoming visible; nothing runs while the page is hidden.
  var t = null, dirtyRoots = [], dirtyFull = false, hiddenDirty = false;
  function flush() {
    t = null;
    if (document.hidden) { hiddenDirty = true; dirtyRoots = []; dirtyFull = false; return; }
    injectInto(document);
    if (dirtyFull) { dirtyFull = false; dirtyRoots = []; apply(); return; }
    var roots = dirtyRoots; dirtyRoots = [];
    for (var i = 0; i < roots.length; i++) {
      var r = roots[i];
      if (!r || !r.isConnected) continue;
      applyTo(r);
    }
  }
  function schedule(muts) {
    for (var i = 0; i < muts.length; i++) {
      var n = muts[i].target;
      if (n.nodeType !== 1) n = n.parentElement;
      if (!n) continue;
      if (n === document.documentElement || n === document.body) dirtyFull = true;
      else if (!dirtyFull && dirtyRoots.length < 64) {
        if (dirtyRoots.indexOf(n) === -1) dirtyRoots.push(n);
      } else dirtyFull = true;
    }
    if (!t) t = setTimeout(flush, 150);
  }
  // At DocumentCreation <html> may not exist yet; wait for documentElement, then
  // apply + start the observer. NOT observing 'style' — sweep writes inline
  // styles, and watching them would retrigger the observer in a tight loop.
  function boot() {
    if (!document.documentElement) { setTimeout(boot, 0); return; }
    apply();
    if (!window.__qsElTransWired) {
      window.__qsElTransWired = true;
      try {
        new MutationObserver(schedule).observe(document.documentElement,
          { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
      } catch (e) {}
      document.addEventListener('visibilitychange', function () {
        if (!document.hidden && hiddenDirty) { hiddenDirty = false; apply(); }
      });
    }
  }
  boot();
})();
