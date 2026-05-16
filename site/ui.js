// shared UI primitives for leaflet-search:
//   - longPress(el, fn): 300ms hold on touch OR right-click on pointer
//   - bindContextMenu(triggerEl, getItems): wraps longPress + showMenu
//   - showMenu(items, anchor): bottom-sheet on phone, popover on pointer
//   - setupTypeahead(input, opts): full-screen sheet on phone, popover on
//     desktop. integrates the context menu on each suggestion via long-press.
//   - openSettings(): preferred-client picker modal
//
// depends on window.LeafletClients (clients.js).

(function() {
  'use strict';

  var MOBILE_BP = 600;
  var LONG_PRESS_MS = 300;
  var TYPEAHEAD_BASE = 'https://typeahead.waow.tech';

  function isMobile() {
    return window.innerWidth < MOBILE_BP;
  }

  function escapeAttr(s) {
    return String(s).replace(/[&<>"']/g, function(c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
    });
  }

  // ---------- long-press / contextmenu binding ----------

  function longPress(el, fn) {
    var timer = null;
    var startX = 0, startY = 0;
    var fired = false;

    function clear() {
      if (timer) { clearTimeout(timer); timer = null; }
    }

    el.addEventListener('touchstart', function(e) {
      var t = e.touches[0];
      startX = t.clientX; startY = t.clientY;
      fired = false;
      clear();
      timer = setTimeout(function() {
        timer = null;
        fired = true;
        fn(e, t.clientX, t.clientY);
      }, LONG_PRESS_MS);
    }, { passive: true });

    el.addEventListener('touchmove', function(e) {
      if (!timer) return;
      var t = e.touches[0];
      if (Math.abs(t.clientX - startX) > 8 || Math.abs(t.clientY - startY) > 8) clear();
    }, { passive: true });

    el.addEventListener('touchend', clear, { passive: true });
    el.addEventListener('touchcancel', clear, { passive: true });

    // suppress the click that follows a long-press on touch
    el.addEventListener('click', function(e) {
      if (fired) {
        e.preventDefault();
        e.stopPropagation();
        fired = false;
      }
    }, true);

    // pointer right-click
    el.addEventListener('contextmenu', function(e) {
      e.preventDefault();
      fn(e, e.clientX, e.clientY);
    });
  }

  // ---------- context menu ----------

  var openMenu = null;

  function closeMenu() {
    if (openMenu) {
      openMenu.remove();
      openMenu = null;
      document.removeEventListener('keydown', menuKey, true);
    }
  }

  function menuKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); closeMenu(); }
  }

  function showMenu(items, x, y) {
    closeMenu();
    if (!items || items.length === 0) return;

    var sheet = document.createElement('div');
    sheet.className = 'lf-contextmenu' + (isMobile() ? ' lf-contextmenu-sheet' : ' lf-contextmenu-popover');
    sheet.setAttribute('role', 'menu');

    sheet.innerHTML = items.map(function(it, i) {
      if (it.divider) return '<div class="lf-menu-divider"></div>';
      var icon = it.iconUrl ? '<img class="lf-menu-icon" src="' + escapeAttr(it.iconUrl) + '" alt="">' : '';
      return '<button class="lf-menu-item" data-i="' + i + '" role="menuitem">' +
        icon + '<span class="lf-menu-label">' + escapeAttr(it.label) + '</span>' +
        '</button>';
    }).join('');

    if (isMobile()) {
      var backdrop = document.createElement('div');
      backdrop.className = 'lf-contextmenu-backdrop';
      backdrop.addEventListener('click', closeMenu);
      document.body.appendChild(backdrop);
      document.body.appendChild(sheet);
      // animate up
      requestAnimationFrame(function() { sheet.classList.add('open'); backdrop.classList.add('open'); });
      sheet._backdrop = backdrop;
    } else {
      document.body.appendChild(sheet);
      // anchor near cursor, clamp to viewport
      var rect = sheet.getBoundingClientRect();
      var W = window.innerWidth, H = window.innerHeight;
      var left = Math.min(x, W - rect.width - 8);
      var top  = Math.min(y, H - rect.height - 8);
      sheet.style.left = Math.max(8, left) + 'px';
      sheet.style.top  = Math.max(8, top)  + 'px';
      sheet.classList.add('open');
    }

    sheet.addEventListener('click', function(e) {
      var btn = e.target.closest('.lf-menu-item');
      if (!btn) return;
      var idx = parseInt(btn.getAttribute('data-i'), 10);
      var it = items[idx];
      closeMenu();
      if (it && it.onSelect) it.onSelect();
    });

    setTimeout(function() {
      document.addEventListener('click', function dismiss(e) {
        if (!sheet.contains(e.target)) {
          document.removeEventListener('click', dismiss);
          closeMenu();
        }
      });
    }, 0);

    document.addEventListener('keydown', menuKey, true);

    openMenu = {
      remove: function() {
        sheet.remove();
        if (sheet._backdrop) sheet._backdrop.remove();
      },
    };
  }

  function bindContextMenu(el, getItems) {
    longPress(el, function(e, x, y) {
      var items = getItems(e);
      showMenu(items, x, y);
    });
  }

  // ---------- canonical menu builders ----------

  function copyToClipboard(text) {
    try { navigator.clipboard.writeText(text); } catch (e) {}
  }

  // build the per-author menu — used both on result-row @handle and on
  // typeahead suggestions. accepts handle (no leading @) and did.
  function authorMenuItems(handle, did) {
    var clients = window.LeafletClients.CLIENTS;
    var items = [
      { label: 'View on atlas', onSelect: function() {
        location.href = '/atlas.html?q=' + encodeURIComponent('@' + handle);
      }},
      { divider: true },
    ];
    clients.forEach(function(c) {
      items.push({
        label: 'Open in ' + c.label,
        iconUrl: c.iconUrl,
        onSelect: function() { window.open(c.profileUrl(did || handle), '_blank'); },
      });
    });
    items.push({ divider: true });
    items.push({ label: 'Copy handle', onSelect: function() { copyToClipboard('@' + handle); } });
    return items;
  }

  function publicationMenuItems(basePath, externalUrl) {
    var items = [];
    if (basePath) {
      items.push({ label: 'View on atlas', onSelect: function() {
        location.href = '/atlas.html?pub=' + encodeURIComponent(basePath);
      }});
    }
    if (externalUrl) {
      items.push({ label: 'Open site', onSelect: function() { window.open(externalUrl, '_blank'); } });
      items.push({ divider: true });
      items.push({ label: 'Copy link', onSelect: function() { copyToClipboard(externalUrl); } });
    }
    return items;
  }

  function rowMenuItems(opts) {
    var items = [];
    if (opts.uri) {
      items.push({ label: 'View document on atlas', onSelect: function() {
        location.href = '/atlas.html?uri=' + encodeURIComponent(opts.uri);
      }});
    }
    if (opts.basePath) {
      items.push({ label: 'View publication on atlas', onSelect: function() {
        location.href = '/atlas.html?pub=' + encodeURIComponent(opts.basePath);
      }});
    }
    if (opts.handle) {
      items.push({ label: 'View author on atlas', onSelect: function() {
        location.href = '/atlas.html?q=' + encodeURIComponent('@' + opts.handle);
      }});
    }
    if (opts.externalUrl) {
      items.push({ divider: true });
      items.push({ label: 'Copy link', onSelect: function() { copyToClipboard(opts.externalUrl); } });
    }
    return items;
  }

  // ---------- typeahead ----------

  function setupTypeahead(input, opts) {
    opts = opts || {};
    var DEBOUNCE_MS = 150;
    var LIMIT = 8;

    // dropdown for desktop is positioned below the input;
    // on phone we lift the input into a full-screen sheet at focus time.
    var dropdown = document.createElement('div');
    dropdown.className = 'lf-typeahead-dropdown';
    dropdown.setAttribute('role', 'listbox');
    input.parentNode.appendChild(dropdown);

    var sheet = null;       // full-screen sheet element (created on phone focus)
    var sheetInput = null;  // the input inside the sheet (mirrors `input`)
    var activeInput = input;
    var activeList = dropdown;

    var timer = null;
    var items = [];
    var selected = -1;
    var lastFetched = '';
    var matchInfo = null;

    function findHandlePartial(el) {
      var v = el.value;
      var caret = el.selectionStart;
      if (caret == null) caret = v.length;
      var i = caret;
      while (i > 0 && /[\w.-]/.test(v[i - 1])) i--;
      if (v[i - 1] !== '@') return null;
      var atIdx = i - 1;
      var before = atIdx === 0 ? '' : v[atIdx - 1];
      if (before && !/\s/.test(before)) return null;
      return { start: atIdx, end: caret, partial: v.slice(i, caret) };
    }

    function hide() {
      activeList.classList.remove('open');
      activeList.innerHTML = '';
      items = [];
      selected = -1;
    }

    function render() {
      activeList.innerHTML = items.map(function(a, i) {
        var dn = a.displayName ? '<span class="lf-typeahead-name">' + escapeAttr(a.displayName) + '</span>' : '';
        var av = a.avatar
          ? '<img class="lf-typeahead-avatar" src="' + escapeAttr(a.avatar) + '" loading="lazy" alt="">'
          : '<span class="lf-typeahead-avatar lf-typeahead-avatar-ph"></span>';
        return '<div class="lf-typeahead-item' + (i === selected ? ' active' : '') +
          '" data-i="' + i + '" role="option">' + av +
          '<div class="lf-typeahead-text"><span class="lf-typeahead-handle">@' + escapeAttr(a.handle) + '</span>' + dn + '</div>' +
          '</div>';
      }).join('');
      activeList.classList.toggle('open', items.length > 0);
    }

    function pick(idx) {
      var a = items[idx];
      var info = matchInfo;
      if (!a || !info) return;
      var v = activeInput.value;
      activeInput.value = v.slice(0, info.start) + '@' + a.handle + ' ' + v.slice(info.end);
      // also sync the underlying page input if we're in sheet mode
      if (activeInput !== input) input.value = activeInput.value;
      hide();
      if (sheet) closeSheet();
      if (opts.onPick) opts.onPick(a);
    }

    function maybeFetch() {
      var info = findHandlePartial(activeInput);
      matchInfo = info;
      if (!info || info.partial.length < 1) { hide(); return; }
      if (info.partial === lastFetched) return;
      lastFetched = info.partial;
      var query = info.partial;
      fetch(TYPEAHEAD_BASE + '/xrpc/app.bsky.actor.searchActorsTypeahead?q=' +
        encodeURIComponent(query) + '&limit=' + LIMIT)
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(d) {
          if (!d || !matchInfo || matchInfo.partial !== query) return;
          items = (d.actors || []).slice(0, LIMIT);
          selected = items.length > 0 ? 0 : -1;
          render();
          // attach a long-press menu to each rendered item
          activeList.querySelectorAll('.lf-typeahead-item').forEach(function(el, i) {
            bindContextMenu(el, function() {
              var a = items[i];
              return authorMenuItems(a.handle, a.did);
            });
          });
        })
        .catch(function() {});
    }

    function bindInput(el) {
      el.addEventListener('input', function() {
        if (timer) clearTimeout(timer);
        timer = setTimeout(maybeFetch, DEBOUNCE_MS);
      });
      el.addEventListener('keydown', function(e) {
        if (!activeList.classList.contains('open')) return;
        if (e.key === 'ArrowDown') {
          e.preventDefault(); selected = (selected + 1) % items.length; render();
        } else if (e.key === 'ArrowUp') {
          e.preventDefault(); selected = (selected - 1 + items.length) % items.length; render();
        } else if (e.key === 'Enter') {
          e.preventDefault(); e.stopImmediatePropagation(); pick(selected);
        } else if (e.key === 'Escape') {
          e.preventDefault(); e.stopImmediatePropagation();
          if (sheet) closeSheet(); else hide();
        } else if (e.key === 'Tab') {
          pick(selected);
        }
      });
    }

    bindInput(input);

    activeList.addEventListener('mousedown', function(e) {
      var t = e.target.closest('.lf-typeahead-item');
      if (!t) return;
      e.preventDefault();
      pick(parseInt(t.getAttribute('data-i'), 10));
    });

    document.addEventListener('click', function(e) {
      if (sheet) return; // sheet manages its own dismissal
      if (!input.contains(e.target) && !dropdown.contains(e.target)) hide();
    });

    input.addEventListener('blur', function() {
      if (sheet) return;
      setTimeout(hide, 150);
    });

    // ---- mobile full-screen sheet ----
    function openSheet() {
      sheet = document.createElement('div');
      sheet.className = 'lf-typeahead-sheet';
      sheet.innerHTML =
        '<div class="lf-typeahead-sheet-bar">' +
          '<input type="text" class="lf-typeahead-sheet-input" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false">' +
          '<button type="button" class="lf-typeahead-sheet-cancel">Cancel</button>' +
        '</div>' +
        '<div class="lf-typeahead-sheet-list" role="listbox"></div>';
      document.body.appendChild(sheet);

      sheetInput = sheet.querySelector('.lf-typeahead-sheet-input');
      sheetInput.value = input.value;
      sheetInput.placeholder = input.placeholder || 'search...';
      var sheetList = sheet.querySelector('.lf-typeahead-sheet-list');

      activeInput = sheetInput;
      activeList = sheetList;

      bindInput(sheetInput);
      sheetList.addEventListener('mousedown', function(e) {
        var t = e.target.closest('.lf-typeahead-item');
        if (!t) return;
        e.preventDefault();
        pick(parseInt(t.getAttribute('data-i'), 10));
      });
      sheetList.addEventListener('click', function(e) {
        // touch devices fire click not mousedown
        var t = e.target.closest('.lf-typeahead-item');
        if (!t) return;
        pick(parseInt(t.getAttribute('data-i'), 10));
      });

      sheet.querySelector('.lf-typeahead-sheet-cancel').addEventListener('click', closeSheet);

      // focus synchronously so we stay inside the user-activation chain
      // (iOS requirement for showing the soft keyboard). animate the
      // slide-up on the next frame.
      sheetInput.focus();
      requestAnimationFrame(function() { sheet.classList.add('open'); });
    }

    function closeSheet() {
      if (!sheet) return;
      sheet.remove();
      sheet = null;
      sheetInput = null;
      activeInput = input;
      activeList = dropdown;
      hide();
    }

    // gate the full-screen mobile sheet on real user interaction —
    // otherwise an `autofocus` attribute pops the sheet on page load.
    var userInteracted = false;
    function markInteracted() { userInteracted = true; }
    window.addEventListener('pointerdown', markInteracted, { capture: true, once: true });
    window.addEventListener('keydown', markInteracted, { capture: true, once: true });
    window.addEventListener('touchstart', markInteracted, { capture: true, once: true, passive: true });

    // also: if autofocus has already landed on the input by the time we
    // run, blur it on mobile so the sheet doesn't open on first focus.
    if (isMobile() && document.activeElement === input) input.blur();

    input.addEventListener('focus', function() {
      if (!userInteracted) return;
      if (isMobile() && !sheet) {
        // call openSheet SYNCHRONOUSLY inside the focus event so the
        // sheet input's focus() preserves the user-activation chain.
        // iOS Safari refuses to show the keyboard otherwise.
        openSheet();
        input.blur();
      }
    });
  }

  // ---------- settings sheet ----------

  function openSettings() {
    closeMenu();
    var current = window.LeafletClients.getPreferredClient().value;

    var sheet = document.createElement('div');
    sheet.className = 'lf-settings-sheet';
    var clientsHtml = window.LeafletClients.CLIENTS.map(function(c) {
      return '<button type="button" class="lf-client-btn' + (c.value === current ? ' active' : '') +
        '" data-v="' + escapeAttr(c.value) + '" title="' + escapeAttr(c.label) + '" aria-label="' + escapeAttr(c.label) + '">' +
        '<img src="' + escapeAttr(c.iconUrl) + '" alt=""><span>' + escapeAttr(c.label) + '</span></button>';
    }).join('');
    // copy uses "bsky" as the canonical umbrella (covers bluesky / blacksky
     // / etc.). "long-press or right-click" is honest across touch + pointer.
    sheet.innerHTML =
      '<div class="lf-settings-card">' +
        '<div class="lf-settings-head"><h3>settings</h3><button class="lf-settings-close" aria-label="close">&#x2715;</button></div>' +
        '<div class="lf-settings-group">' +
          '<label>preferred bsky client</label>' +
          '<p class="lf-settings-hint">tapping a @handle opens that profile in your preferred client. long-press or right-click for more options.</p>' +
          '<div class="lf-client-picker">' + clientsHtml + '</div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(sheet);

    function close() {
      sheet.classList.remove('open');
      setTimeout(function() { sheet.remove(); document.removeEventListener('keydown', onKey, true); }, 200);
    }
    function onKey(e) { if (e.key === 'Escape') { e.preventDefault(); close(); } }

    sheet.addEventListener('click', function(e) {
      if (e.target === sheet) close();
      var btn = e.target.closest('.lf-client-btn');
      if (btn) {
        var v = btn.getAttribute('data-v');
        window.LeafletClients.setPreferredClient(v);
        sheet.querySelectorAll('.lf-client-btn').forEach(function(b) { b.classList.toggle('active', b === btn); });
        return;
      }
      if (e.target.closest('.lf-settings-close')) close();
    });
    document.addEventListener('keydown', onKey, true);

    requestAnimationFrame(function() { sheet.classList.add('open'); });
  }

  window.LeafletUI = {
    longPress: longPress,
    bindContextMenu: bindContextMenu,
    showMenu: showMenu,
    setupTypeahead: setupTypeahead,
    openSettings: openSettings,
    authorMenuItems: authorMenuItems,
    publicationMenuItems: publicationMenuItems,
    rowMenuItems: rowMenuItems,
    isMobile: isMobile,
  };
})();
