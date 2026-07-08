// Hermes dashboard injection for the obsidian-shell notes hub:
//  (a) "zen mode" — hide the app chrome (top <header> + #app-sidebar nav) so only
//      the chat remains;
//  (b) transparency — strip EVERY background so the matugen window shows through;
//  (c) panels/popups → 10% — any floating, high-z-index box (which is what menus,
//      dialogs, popovers, dropdowns, tooltips ARE, regardless of Tailwind class
//      names) plus role-tagged surfaces get a 10%-opaque matugen tint + blur so
//      they stay legible without being solid. Self-persists via a MutationObserver
//      (Hermes is a React SPA that re-renders).
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

  var css = [
    // ── ZEN MODE: hide ALL app chrome so only the chat remains. The dashboard's
    //    own top <header> and #app-sidebar nav (Chat / Sessions / …) are removed
    //    — session switching is handled by the native QML sessions panel in the
    //    obsidian-shell host (a button in the selector opens it over the chat).
    //    The chat view's own "Chat | Model & tools" sub-header is hidden too.
    "header, #app-sidebar { display: none !important; }",
    // With the headers gone, the chat view's own top padding is dead space —
    // pull the terminal flush to the top so the TUI's context row sits right
    // under the obsidian-shell selector strip (no big gap). :has() scopes it
    // to containers that actually hold the chat terminal.
    "main:has(.hermes-chat-xterm-host), main:has(.hermes-chat-xterm-host) > div," +
    "  div:has(> .hermes-chat-xterm-host) { padding-top: 0 !important; margin-top: 0 !important; }",
    // The app shell's OUTER wrapper reserves the fixed header's height as
    // padding-top (52.5px, measured via CDP) — with the header zen-hidden that
    // is pure dead space above the chat. Zero padding-top on every ancestor of
    // the terminal host (all the others already have 0, so this is surgical).
    "div:has(.hermes-chat-xterm-host) { padding-top: 0 !important; }",
    // ── remove the decorative background picture ──
    // Hermes renders its filler artwork as a real <img class="theme-default-filler"
    // src="/assets/filler-bg0…webp"> (full-bleed, aria-hidden). It's image CONTENT,
    // not a CSS background, so `background-image:none` below can't touch it — it has
    // to be hidden outright. Hermes' own CSS shows this img only when no custom theme
    // bg is set (`.theme-default-filler{display:block}`), so this just turns it off.
    ".theme-default-filler { display: none !important; }",
    // Belt-and-braces for the variable-driven theme bg layer (background-image:
    // var(--theme-asset-bg)) in case a custom theme image ever gets set: neutralise
    // the variable so that layer resolves to no image either.
    ":root { --theme-asset-bg: none !important; }",
    // ── transparency: strip every background ──
    "*, *::before, *::after { background-color: transparent !important; background-image: none !important; }",
    "html, body, #root, main, #root > div { background: transparent !important; }",
    // ── panels/popups (tagged by the JS detector below) → 10% tint + blur ──
    ".qs-panel10 {" +
      "background-color: " + panelBg + " !important;" +
      "-webkit-backdrop-filter: blur(12px) !important; backdrop-filter: blur(12px) !important;" +
      "border: 1px solid " + panelBd + " !important; border-radius: 10px !important;" +
    "}"
  ].join("\n");

  function injectCss() {
    // head, else <html>; never the document node (see the obsidian/dify note on why
    // appending a <style> to the document corrupts the page). Skip until ready.
    var host = document.head || document.documentElement;
    if (!host) return;
    var s = document.getElementById("hermes-zen");
    if (!s) {
      s = document.createElement("style");
      s.id = "hermes-zen";
      host.appendChild(s);
    }
    if (s.textContent !== css) s.textContent = css;
  }

  // Tag floating popups/panels so the CSS above tints them 10%. Popups are always
  // position:fixed/absolute with a real z-index — that catches them no matter what
  // their (Tailwind) class names are; role-tagged surfaces are caught too.
  var ROLE = /^(dialog|menu|listbox|tooltip|alertdialog|combobox)$/i;
  // Tag panels within ONE root (document or a mutated subtree). Limits the walk
  // to plausibly-floating nodes (cheap) instead of every element.
  var TAG_SEL = '[role],[aria-modal="true"],[data-radix-popper-content-wrapper],' +
                '[data-headlessui-portal],[data-state="open"],[class*="fixed" i],[class*="absolute" i]';
  function tagIn(root) {
    var nodes = root.querySelectorAll(TAG_SEL);
    // querySelectorAll only returns descendants — consider an element root too.
    if (root.nodeType === 1 && root.matches && root.matches(TAG_SEL))
      nodes = [root].concat(Array.prototype.slice.call(nodes));
    for (var i = 0; i < nodes.length; i++) {
      var e = nodes[i], cs = getComputedStyle(e);
      // The nav header/sidebar are fixed+big so they'd be tagged as panels and
      // dropped to the 10% tint — skip them; they get their own solid bg above.
      if (e.id === 'app-sidebar' || e.tagName === 'HEADER') { e.classList.remove('qs-panel10'); continue; }
      var r = e.getBoundingClientRect();
      // Skip DECORATIVE full-bleed overlay layers: the dashboard has several
      // `pointer-events-none fixed inset-0` glow/gradient layers covering the whole
      // viewport at high z-index. Tagging them applied .qs-panel10's backdrop-filter
      // blur over the ENTIRE UI (incl. the nav). They're not popups, so skip both
      // pointer-events:none elements and anything ~viewport-sized.
      var fullBleed = r.width >= window.innerWidth - 4 && r.height >= window.innerHeight - 4;
      if (cs.pointerEvents === 'none' || fullBleed) { e.classList.remove('qs-panel10'); continue; }
      var floating = (cs.position === 'fixed' || cs.position === 'absolute');
      var z = parseInt(cs.zIndex, 10) || 0;
      var big = r.width >= 60 && r.height >= 24;
      var isPanel = ROLE.test(e.getAttribute('role') || '') ||
                    e.hasAttribute('aria-modal') ||
                    e.hasAttribute('data-radix-popper-content-wrapper') ||
                    (floating && z >= 20 && big);
      if (isPanel) e.classList.add('qs-panel10');
      else if (e.classList.contains('qs-panel10')) e.classList.remove('qs-panel10');
    }
  }

  // Primary, reliable lever: drive Hermes' background DESIGN TOKENS to transparent.
  // The theme defines full-colour tokens (--background / --background-base, both real
  // hex), and the derived surface tokens are color-mix(... var(--background-base)),
  // so zeroing the base cascades the whole palette to transparent (cards/popovers/
  // muted become faint translucent accent tints over nothing). We set them INLINE on
  // <html> and <body> with !important — that beats whichever theme class defines them,
  // regardless of selector specificity, and is cheap (a couple of elements, no walk).
  var BG_TOKENS = ['--background', '--background-base'];
  function forceTokens() {
    var els = [document.documentElement, document.body];
    for (var i = 0; i < els.length; i++) {
      if (!els[i]) continue;
      for (var j = 0; j < BG_TOKENS.length; j++)
        els[i].style.setProperty(BG_TOKENS[j], 'transparent', 'important');
    }
  }
  // Backstop sweep (Hermes had none — a big reason it was flaky). Read each element's
  // COMPUTED background; if fully opaque ("rgb(...)", no alpha) force it transparent
  // inline. Already-translucent backgrounds (incl. the .qs-panel10 tints and the
  // token-derived faint surfaces) return "rgba(...,a<1)" and are left untouched.
  function sweep(root) {
    var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    // querySelectorAll only returns DESCENDANTS — include an element root itself
    // so an incremental sweep of a mutated element also fixes that element.
    if (root.nodeType === 1) all = [root].concat(Array.prototype.slice.call(all));
    for (var i = 0; i < all.length; i++) {
      var e = all[i], bg;
      try { bg = getComputedStyle(e).backgroundColor; } catch (err) { continue; }
      if (bg && bg.indexOf('rgb(') === 0) {
        e.style.setProperty('background-color', 'transparent', 'important');
        e.style.setProperty('background-image', 'none', 'important');
      }
    }
  }
  // NB: the chat TEXT colour is themed at the SOURCE now — the Hermes "matugen"
  // skin (~/.hermes/skins/matugen.yaml, generated from qs_colors.json by
  // ~/.hermes/gen-matugen-skin.py, selected via display.skin) makes the TUI emit
  // matugen colours directly, so there's no DOM colour-patching here. This file
  // only handles the zen layout + transparency.
  // Merge the two stacked top bars into one: the dashboard renders a "Hermes
  // Agent" nav header AND, below it, the chat view's own "Chat | Model & tools"
  // header. Relocate the chat/models controls up into the Hermes Agent bar and
  // hide the now-empty chat header, so there's a single integrated top bar.
  // Idempotent + re-run by the observer: if React re-renders the chat header, the
  // fresh controls are moved up and the previously-relocated copy is dropped.
  function mergeHeaders() {
    return;   // zen mode hides all chrome — nothing to merge/relocate.
    var hs = document.querySelectorAll('header');
    var nav = null, chat = null;
    for (var i = 0; i < hs.length; i++)
      if (/hermes agent/i.test(hs[i].textContent || '')) { nav = hs[i]; break; }
    for (var j = 0; j < hs.length; j++)
      if (hs[j] !== nav && /\bshrink-0\b/.test(hs[j].className || '')) { chat = hs[j]; break; }
    if (!nav || !chat) return;                     // wide layout / not mounted yet
    var inner = chat.firstElementChild;
    if (!inner) { chat.style.setProperty('display', 'none', 'important'); return; }
    if (!inner.hasAttribute('data-qs-merged')) {
      var old = nav.querySelector('[data-qs-merged]');   // stale copy from a prior render
      if (old && old !== inner) old.remove();
      inner.setAttribute('data-qs-merged', '1');
      inner.style.setProperty('flex', '1', 'important');
      nav.style.setProperty('justify-content', 'flex-start', 'important');
      nav.appendChild(inner);
    }
    chat.style.setProperty('display', 'none', 'important');
  }
  function apply() { injectCss(); forceTokens(); tagIn(document); try { sweep(document); } catch (e) {} try { mergeHeaders(); } catch (e) {} }

  // ── Incremental re-apply machinery ──────────────────────────────────────
  // The old observer re-ran the FULL apply() (document-wide querySelectorAll('*')
  // + getComputedStyle + getBoundingClientRect) on every mutation burst — a
  // continuous forced style/layout pass while the chat streams tokens, even
  // with the page HIDDEN. Now mutations sweep/tag only their own subtree
  // roots; a full pass runs only at boot, on <html>/<body> class changes, on
  // root overflow, or on becoming visible again (nothing runs while hidden).
  var t = null, dirtyRoots = [], dirtyFull = false, hiddenDirty = false;
  function flush() {
    t = null;
    if (document.hidden) { hiddenDirty = true; dirtyRoots = []; dirtyFull = false; return; }
    injectCss();
    forceTokens();
    if (dirtyFull) { dirtyFull = false; dirtyRoots = []; apply(); return; }
    var roots = dirtyRoots; dirtyRoots = [];
    for (var i = 0; i < roots.length; i++) {
      var r = roots[i];
      if (!r || !r.isConnected) continue;
      try { tagIn(r); } catch (e) {}
      try { sweep(r); } catch (e) {}
    }
    try { mergeHeaders(); } catch (e) {}   // cheap (few <header> nodes), keeps the merged bar
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
  // Wait for <html> before applying/observing (DocumentCreation may run before it).
  function boot() {
    if (!document.documentElement) { setTimeout(boot, 0); return; }
    apply();
    // NOT 'style' — forceTokens()/sweep() write inline styles, and observing them would
    // retrigger this observer in a tight loop. class/role/childList cover React re-renders.
    try { new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'role'] }); } catch (e) {}
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && hiddenDirty) { hiddenDirty = false; apply(); }
    });
  }
  boot();
})();
