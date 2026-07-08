// Transparency injection for the Dify web UI (the "learn" hub view, :8090):
//  (a) strip EVERY background so the matugen window shows through;
//  (b) panels/popups → 10% — any floating, high-z-index box (menus, dialogs,
//      popovers, dropdowns, tooltips, the chat side panels — whatever their class
//      names) plus role-tagged surfaces get a 10%-opaque matugen tint + blur so
//      they stay legible without being solid.
// Self-persists via a MutationObserver (also walks shadow roots); Dify is a
// React/Tailwind SPA.
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
  var panelBg = rgba(C.surface1 || '#45475a', 0.1);
  var panelBd = rgba(C.surface2 || '#585b70', 0.18);

  var css =
    // 1) strip every background.
    '*,*::before,*::after{background-color:transparent!important;background-image:none!important;}' +
    'html,body,#root,main{background:transparent!important;}' +
    // 2) panels/popups (tagged by the JS detector below) → 10% tint + blur.
    '.qs-panel10{' +
      'background-color:' + panelBg + '!important;' +
      '-webkit-backdrop-filter:blur(12px)!important;backdrop-filter:blur(12px)!important;' +
      'border:1px solid ' + panelBd + '!important;border-radius:10px!important;}';

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
    var s = root.querySelector ? root.querySelector('#qs-dify-transparent') : null;
    if (!s) {
      s = document.createElement('style');
      s.id = 'qs-dify-transparent';
      host.appendChild(s);
    }
    if (s.textContent !== css) s.textContent = css;
  }

  // Tag floating popups/panels so the CSS above tints them 10%. Popups are always
  // position:fixed/absolute with a real z-index — catches them regardless of class.
  var ROLE = /^(dialog|menu|listbox|tooltip|alertdialog|combobox)$/i;
  function tagIn(root) {
    var nodes = root.querySelectorAll(
      '[role],[aria-modal="true"],[data-radix-popper-content-wrapper],' +
      '[data-headlessui-portal],[data-state="open"],[class*="fixed" i],[class*="absolute" i]');
    for (var i = 0; i < nodes.length; i++) {
      var e = nodes[i], cs = getComputedStyle(e);
      var floating = (cs.position === 'fixed' || cs.position === 'absolute');
      var z = parseInt(cs.zIndex, 10) || 0;
      var r = e.getBoundingClientRect();
      var big = r.width >= 60 && r.height >= 24;
      var isPanel = ROLE.test(e.getAttribute('role') || '') ||
                    e.hasAttribute('aria-modal') ||
                    e.hasAttribute('data-radix-popper-content-wrapper') ||
                    (floating && z >= 20 && big);
      if (isPanel) e.classList.add('qs-panel10');
      else if (e.classList.contains('qs-panel10')) e.classList.remove('qs-panel10');
    }
  }
  // Definitive backstop. Tailwind utilities like `.bg-white` (specificity 0,1,0)
  // and the SPA's loading-screen overlay outrank the `*` rule, so the stylesheet
  // alone can't strip them. Read each element's COMPUTED background and, if it's
  // fully opaque, force it transparent inline (inline !important wins regardless of
  // selector specificity). Already-translucent backgrounds — including the 10%
  // `.qs-panel10` tints — return "rgba(...,a<1)" and are left untouched.
  function sweep(root) {
    var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    // querySelectorAll only returns DESCENDANTS — include an element root itself
    // so an incremental sweep of a mutated element also fixes that element.
    if (root.nodeType === 1) all = [root].concat(Array.prototype.slice.call(all));
    for (var i = 0; i < all.length; i++) {
      var e = all[i];
      var bg;
      try { bg = getComputedStyle(e).backgroundColor; } catch (err) { continue; }
      if (bg && bg.indexOf('rgb(') === 0) {     // "rgb(...)" == fully opaque
        e.style.setProperty('background-color', 'transparent', 'important');
        e.style.setProperty('background-image', 'none', 'important');
      }
    }
  }
  function walk(node) {
    if (node.shadowRoot) {
      injectInto(node.shadowRoot);
      try { tagIn(node.shadowRoot); } catch (e) {}
      try { sweep(node.shadowRoot); } catch (e) {}
      node.shadowRoot.querySelectorAll('*').forEach(walk);
    }
  }
  // Primary, reliable lever: drive Dify's background DESIGN TOKENS to transparent.
  // Dify's theme defines full-colour tokens (real hex), with the page background as
  // `body{background-color:var(--color-background-body)}` and surfaces/panels/cards on
  // their own tokens. Overriding these INLINE on <html>+<body> with !important beats
  // whichever theme class defines them (inline wins over any selector) and is cheap.
  // We leave chat-bubble gradients / inputs alone so the conversation stays readable;
  // the sweep + .qs-panel10 tinting handle anything else.
  var BG_TOKENS = [
    '--color-background-body',
    '--color-background-default',
    '--color-background-default-subtle',
    '--color-components-panel-bg',
    '--color-components-panel-bg-blur',
    '--color-components-card-bg'
  ];
  function forceTokens() {
    var els = [document.documentElement, document.body];
    for (var i = 0; i < els.length; i++) {
      if (!els[i]) continue;
      for (var j = 0; j < BG_TOKENS.length; j++)
        els[i].style.setProperty(BG_TOKENS[j], 'transparent', 'important');
    }
  }
  // Re-apply everything for one SUBTREE only (the incremental path).
  function applyTo(root) {
    try { tagIn(root); } catch (e) {}
    try { sweep(root); } catch (e) {}
    try { walk(root); root.querySelectorAll('*').forEach(walk); } catch (e) {}
  }
  function apply() {
    injectInto(document);
    forceTokens();
    tagIn(document);
    try { sweep(document); } catch (e) {}
    document.querySelectorAll('*').forEach(walk);
  }

  // ── Incremental re-apply machinery ──────────────────────────────────────
  // The old observer re-ran the FULL apply() (document-wide querySelectorAll('*')
  // + getComputedStyle) on every mutation burst — continuous forced style
  // recalc while the SPA re-renders, even with the page HIDDEN. Now mutations
  // sweep only their own subtree roots; a full pass runs only at boot, on
  // <html>/<body> class changes, on root overflow, or on becoming visible
  // again (nothing at all runs while hidden).
  var t = null, dirtyRoots = [], dirtyFull = false, hiddenDirty = false;
  function flush() {
    t = null;
    if (document.hidden) { hiddenDirty = true; dirtyRoots = []; dirtyFull = false; return; }
    injectInto(document);
    forceTokens();
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
    if (!t) t = setTimeout(flush, 120);
  }
  // At DocumentCreation <html> may not exist yet; observe(null) would throw and we
  // could inject too early, so wait for documentElement, then apply + start observing.
  function boot() {
    if (!document.documentElement) { setTimeout(boot, 0); return; }
    apply();
    // NOT 'style' — sweep writes inline styles, and observing them would retrigger
    // this observer in a tight loop. class/role/childList changes (plus the per-open
    // re-inject burst from the QML side) cover Dify's React re-renders.
    try { new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'role'] }); } catch (e) {}
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && hiddenDirty) { hiddenDirty = false; apply(); }
    });
  }
  boot();
})();
