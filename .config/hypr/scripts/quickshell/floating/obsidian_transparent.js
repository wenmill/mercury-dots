// Transparency injection for the Ignis (Obsidian-as-web-app) overlay. Ignis
// renders Obsidian as REAL DOM, so we force EVERY background transparent (the
// matugen window background then shows through the whole UI — editor, sidebars,
// ribbon, tab bar, status bar, buttons). The floating surfaces (menus, modals,
// the command palette, tooltips, popovers, suggestion lists) get a 10%-opaque
// matugen tint + blur so they stay distinguishable without being solid panels.
// Self-persists via a MutationObserver (also walks shadow roots).
//
// IMPORTANT: `*{background:transparent}` has the LOWEST CSS specificity, so any
// Obsidian rule on a class (e.g. `.theme-dark`, `.workspace-leaf-content`) beats
// it even with !important. That is what left the view white. So we ALSO target
// Obsidian's real surface classes at class specificity, AND set inline styles on
// the big container elements from JS (inline !important can't be out-specified).
//
// Colours come from window.QS_COLORS, injected ahead of this file by the host.
(function () {
  var C = window.QS_COLORS || {};
  function rgba(hex, a) {
    hex = (hex || '').replace('#', '');
    if (hex.length === 3) hex = hex.split('').map(function (c) { return c + c; }).join('');
    var n = parseInt(hex || '45475a', 16);
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')';
  }
  var surface = C.surface1 || '#45475a';   // matugen card colour for floating UI
  var border  = C.surface2 || '#585b70';
  var text    = C.text     || '#cdd6f4';
  var panelBg = rgba(surface, 0.1);          // 10% opaque panels/popups
  var panelBd = rgba(border, 0.18);

  // Obsidian's opaque surface classes — the ones that actually carry a background.
  // Listed explicitly so the rule is at class specificity and beats `.theme-dark`.
  var SURFACES = [
    'html', 'body', '.app-container', '.titlebar', '.titlebar-inner',
    '.horizontal-main-container', '.workspace', '.workspace-split',
    '.workspace-tabs', '.workspace-tab-container', '.workspace-leaf',
    '.workspace-leaf-content', '.view-content', '.view-header',
    '.markdown-source-view', '.markdown-reading-view', '.markdown-preview-view',
    '.markdown-preview-sizer', '.cm-editor', '.cm-scroller', '.cm-gutters',
    '.cm-sizer', '.workspace-ribbon', '.side-dock-ribbon', '.status-bar',
    '.workspace-tab-header-container', '.workspace-tab-header', '.nav-files-container',
    '.tree-item', '.search-input-container', '.empty-state'
  ].join(',');

  var css =
    // 1) EVERYTHING transparent by default — including ::before/::after and the
    //    Obsidian background design tokens, so nothing paints over the matugen.
    '*,*::before,*::after{background-color:transparent!important;background-image:none!important;}' +
    // 1b) The real Obsidian surfaces at CLASS specificity (beats `.theme-dark`,
    //     `.theme-light`, etc. that the universal selector cannot).
    SURFACES + '{background:transparent!important;background-color:transparent!important;}' +
    // 1c) Drive the theme tokens to transparent on the class that defines them.
    ':root,html,body,.theme-dark,.theme-light{' +
      '--background-primary:transparent!important;' +
      '--background-primary-alt:transparent!important;' +
      '--background-secondary:transparent!important;' +
      '--background-secondary-alt:transparent!important;' +
      '--titlebar-background:transparent!important;' +
      '--titlebar-background-focused:transparent!important;' +
      '--tab-background-active:transparent!important;' +
      '--ribbon-background:transparent!important;' +
      '--cm-gutters-background:transparent!important;' +
      '--background-modifier-form-field:transparent!important;' +
      // collapse the titlebar's reserved height (see the .titlebar rule below).
      '--titlebar-height:0px!important;}' +
    // The Ignis/web Obsidian build has no real window controls, but the .titlebar
    // still reserves vertical space — that's the dark gap above the tab strip.
    // Remove it from flow so the tabs sit flush at the very top.
    '.titlebar{display:none!important;}' +
    // With the titlebar gone, drop any reserved top spacing on the structural
    // containers so the tab strip meets the panel's top edge with no gap.
    '.app-container,.horizontal-main-container,.workspace,.workspace-split,.mod-root,' +
    '.workspace-tabs,.workspace-tab-container,.workspace-tab-header-container{' +
      'margin-top:0!important;padding-top:0!important;}' +
    // 2) floating surfaces: 10% matugen tint + blur so popups/panels read as UI
    //    without being solid. Covers Obsidian's own classes plus generic ones.
    '.menu,.modal,.modal-content,.suggestion-container,.prompt,.tooltip,.popover,' +
    '.hover-popover,.notice,.workspace-drawer,.cm-tooltip,.mobile-toolbar,' +
    '.community-modal,' +
    '[class*="popover" i],[class*="dropdown" i],[class*="popup" i],[role="menu"],' +
    '[role="dialog"],[role="listbox"],[role="tooltip"]{' +
      'background-color:' + panelBg + '!important;' +
      '-webkit-backdrop-filter:blur(12px)!important;backdrop-filter:blur(12px)!important;' +
      'border:1px solid ' + panelBd + '!important;' +
      'border-radius:10px!important;color:' + text + '!important;}' +
    // the modal dimmer behind dialogs: keep it subtle, not opaque black.
    '.modal-bg{background-color:rgba(0,0,0,0.25)!important;}' +
    // the Ignis "Loading Obsidian…" splash is a solid #202020 cover — make it
    // transparent too so there's no opaque slab before Obsidian finishes booting.
    '#ignis-status{background:transparent!important;}';

  // Where to put the <style>. CRITICAL: never the document node itself — at
  // DocumentCreation <html> may not exist yet, and appending a <style> straight to
  // the document makes that <style> the root element, so the parser can never build
  // <html>/<body> (the page renders blank). Use head, else <html>, else (shadow root)
  // the root; return null when the document isn't ready so a later tick injects.
  function styleHost(root) {
    if (root.nodeType === 9) return root.head || root.documentElement || null;  // Document
    return root.head || root;                                                   // ShadowRoot
  }
  function injectInto(root) {
    var host = styleHost(root);
    if (!host) return;
    var s = root.querySelector ? root.querySelector('#qs-obsidian-transparent') : null;
    if (!s) {
      s = document.createElement('style');
      s.id = 'qs-obsidian-transparent';
      host.appendChild(s);
    }
    if (s.textContent !== css) s.textContent = css;
  }

  // Floating UI we deliberately KEEP tinted (10% panel bg from the stylesheet) so
  // popups/menus stay readable — the sweep below must not strip these.
  var KEEP = '.menu,.modal,.modal-content,.suggestion-container,.prompt,.tooltip,' +
             '.popover,.hover-popover,.notice,.workspace-drawer,.cm-tooltip,' +
             '.mobile-toolbar,.community-modal,[class*="popover" i],[class*="dropdown" i],' +
             '[class*="popup" i],[role="menu"],[role="dialog"],[role="listbox"],' +
             '[role="tooltip"],.modal-bg';

  // The definitive backstop. Obsidian's theme uses COMPOUND selectors (e.g.
  // `.theme-dark .markdown-preview-view`, specificity 0,2,0) that outrank our
  // single-class rules (0,1,0) — and !important doesn't break a specificity tie,
  // so the stylesheet alone can't win. So we read each element's COMPUTED
  // background and, if it's fully opaque, force it transparent inline (inline
  // !important beats any stylesheet selector regardless of specificity). Elements
  // that are already translucent (our panel/menu tints are rgba alpha<1) are left
  // untouched, as is anything inside a KEEP surface.
  function sweep(root) {
    var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    // querySelectorAll only returns DESCENDANTS — include an element root itself
    // so an incremental sweep of a mutated element also fixes that element.
    if (root.nodeType === 1) all = [root].concat(Array.prototype.slice.call(all));
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.closest && el.closest(KEEP)) continue;
      var bg;
      try { bg = getComputedStyle(el).backgroundColor; } catch (e) { continue; }
      // getComputedStyle returns "rgb(...)" for fully opaque, "rgba(...,a)" otherwise.
      // Only opaque (no alpha) backgrounds get cleared; translucent tints survive.
      if (bg && bg.indexOf('rgb(') === 0) {
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
  // The old observer re-ran the FULL apply() — a document-wide
  // querySelectorAll('*') + getComputedStyle pass — on every mutation burst,
  // i.e. continuously while typing or while the SPA re-renders, and kept
  // doing so while the page was HIDDEN (panel closed). Now:
  //   • mutations only queue their own subtree roots, swept individually;
  //   • a FULL pass runs only at boot, when <html>/<body> classes change
  //     (theme swap), when too many roots pile up, or on becoming visible;
  //   • while hidden nothing runs at all — a dirty flag defers one full
  //     apply() to the next visibilitychange (and the host's per-open
  //     re-inject burst re-runs this whole script then too).
  var t = null, dirtyRoots = [], dirtyFull = false, hiddenDirty = false;
  function flush() {
    t = null;
    if (document.hidden) { hiddenDirty = true; dirtyRoots = []; dirtyFull = false; return; }
    injectInto(document);                     // idempotent, cheap
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
      } else dirtyFull = true;                // many roots → one full pass is cheaper
    }
    if (!t) t = setTimeout(flush, 150);
  }
  // At DocumentCreation <html> may not exist yet; observe(null) would throw and we
  // could inject too early, so wait for documentElement, then apply + start the
  // observer. This keeps the pre-paint injection while never corrupting the document.
  function boot() {
    if (!document.documentElement) { setTimeout(boot, 0); return; }
    apply();
    // Watch class changes (Obsidian swaps theme classes / re-themes on the fly) and
    // node additions. NOT 'style' — sweep writes inline styles, and observing them
    // would retrigger this observer in a tight loop.
    try { new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] }); } catch (e) {}
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && hiddenDirty) { hiddenDirty = false; apply(); }
    });
  }
  boot();
})();
