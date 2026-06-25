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
    if (e.key === 'Escape') { e.preventDefault(); closeMenu(); return; }
    if (!openMenu || !openMenu.sheet) return;
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp' && e.key !== 'Home' && e.key !== 'End') return;
    e.preventDefault();
    var items = Array.prototype.slice.call(openMenu.sheet.querySelectorAll('.lf-menu-item'));
    if (items.length === 0) return;
    var current = items.indexOf(document.activeElement);
    var next;
    if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = items.length - 1;
    else if (e.key === 'ArrowDown') next = (current + 1 + items.length) % items.length;
    else /* ArrowUp */ next = (current - 1 + items.length) % items.length;
    items[next].focus();
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
      sheet: sheet,
      remove: function() {
        sheet.remove();
        if (sheet._backdrop) sheet._backdrop.remove();
      },
    };

    // Focus the first menu item so keyboard users can immediately use arrows
    // / Enter to act. Without this, the menu opens but focus stays on the
    // trigger and Escape is the only keyboard interaction.
    var first = sheet.querySelector('.lf-menu-item');
    if (first) requestAnimationFrame(function() { first.focus(); });
  }

  function bindContextMenu(el, getItems) {
    longPress(el, function(e, x, y) {
      var items = getItems(e);
      showMenu(items, x, y);
    });
  }

  // ---------- canonical menu builders ----------

  // Brief visual confirmation for clipboard actions. Without it, the right-
  // click "Copy link" / "Copy handle" silently succeeds (or silently fails)
  // and the user has no idea if anything happened.
  var toastEl = null;
  var toastTimer = null;
  function showToast(message) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.className = 'lf-toast';
      toastEl.setAttribute('role', 'status');
      toastEl.setAttribute('aria-live', 'polite');
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = message;
    toastEl.classList.add('open');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function() {
      toastEl.classList.remove('open');
    }, 1500);
  }

  function copyToClipboard(text) {
    var done = false;
    try {
      navigator.clipboard.writeText(text);
      done = true;
    } catch (e) {
      // legacy fallback: hidden input + execCommand. Last resort, may also fail.
      try {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.top = '-1000px';
        document.body.appendChild(ta);
        ta.select();
        done = document.execCommand && document.execCommand('copy');
        ta.remove();
      } catch (e2) {}
    }
    showToast(done ? 'copied' : 'copy failed');
  }

  // Single "Open in <preferred client>" entry — honors the choice the
  // user persisted via openSettings(). The settings sheet is where
  // alternate clients live; the menu just routes to whatever they picked.
  function preferredClientItem(handleOrDid) {
    var c = window.LeafletClients.getPreferredClient();
    return {
      label: 'Open in ' + c.label,
      iconUrl: c.iconUrl,
      onSelect: function() { window.open(c.profileUrl(handleOrDid), '_blank'); },
    };
  }

  // Per-author menu — for the writer of a post (on result-row @handles and
  // typeahead suggestions). "Most-recommended posts BY this author" goes
  // to /recommended?author=did (filters on document author).
  function authorMenuItems(handle, did) {
    var items = [
      { label: 'View on atlas', onSelect: function() {
        location.href = '/atlas.html?q=' + encodeURIComponent('@' + handle);
      }},
    ];
    if (did) {
      items.push({ label: "Most-recommended posts they've written", onSelect: function() {
        location.href = '/recommended.html?author=' + encodeURIComponent(did);
      }});
      items.push({ label: "Posts they've recommended", onSelect: function() {
        location.href = '/recommended.html?curator=' + encodeURIComponent(did);
      }});
    }
    items.push({ divider: true });
    items.push(preferredClientItem(did || handle));
    items.push({ divider: true });
    items.push({ label: 'Copy handle', onSelect: function() { copyToClipboard('@' + handle); } });
    return items;
  }

  // Per-curator menu — for the recommender on /recommended curators rows.
  // Primary action is "posts they've recommended" (?curator=did), NOT
  // "posts they've written" (?author=did) which is often empty for
  // curators. Handle may be empty before identity resolution returns.
  function curatorMenuItems(handle, did) {
    var items = [];
    if (did) {
      items.push({ label: "Posts they've recommended", onSelect: function() {
        location.href = '/recommended.html?curator=' + encodeURIComponent(did);
      }});
      items.push({ label: "Most-recommended posts they've written", onSelect: function() {
        location.href = '/recommended.html?author=' + encodeURIComponent(did);
      }});
    }
    if (handle) {
      items.push({ label: 'View on atlas', onSelect: function() {
        location.href = '/atlas.html?q=' + encodeURIComponent('@' + handle);
      }});
    }
    items.push({ divider: true });
    items.push(preferredClientItem(did || handle));
    if (handle) {
      items.push({ divider: true });
      items.push({ label: 'Copy handle', onSelect: function() { copyToClipboard('@' + handle); } });
    } else if (did) {
      items.push({ divider: true });
      items.push({ label: 'Copy DID', onSelect: function() { copyToClipboard(did); } });
    }
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
    // Cross-page jump from a doc row to leaderboard views of this author.
    // Needs the DID (handle alone isn't enough for the backend filter).
    if (opts.authorDid) {
      items.push({ label: "Most-recommended posts they've written", onSelect: function() {
        location.href = '/recommended.html?author=' + encodeURIComponent(opts.authorDid);
      }});
      items.push({ label: "Posts they've recommended", onSelect: function() {
        location.href = '/recommended.html?curator=' + encodeURIComponent(opts.authorDid);
      }});
    }
    if (opts.externalUrl) {
      items.push({ divider: true });
      items.push({ label: 'Copy link', onSelect: function() { copyToClipboard(opts.externalUrl); } });
    }
    return items;
  }

  // ---------- typeahead ----------

  // single popover dropdown anchored below the input on every viewport.
  // browser-native focus + keyboard behavior; no DOM gymnastics, no sheet,
  // no second input to focus-shuffle into.
  function setupTypeahead(input, opts) {
    opts = opts || {};
    var DEBOUNCE_MS = 150;
    var LIMIT = 8;

    var dropdown = document.createElement('div');
    dropdown.className = 'lf-typeahead-dropdown';
    dropdown.setAttribute('role', 'listbox');
    input.parentNode.appendChild(dropdown);

    var timer = null;
    var items = [];
    var selected = -1;
    var lastFetched = '';
    var matchInfo = null;

    function findHandlePartial() {
      var v = input.value;
      var caret = input.selectionStart;
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
      dropdown.classList.remove('open');
      dropdown.innerHTML = '';
      items = [];
      selected = -1;
    }

    function render() {
      dropdown.innerHTML = items.map(function(a, i) {
        var dn = a.displayName ? '<span class="lf-typeahead-name">' + escapeAttr(a.displayName) + '</span>' : '';
        var av = a.avatar
          ? '<img class="lf-typeahead-avatar" src="' + escapeAttr(a.avatar) + '" loading="lazy" alt="">'
          : '<span class="lf-typeahead-avatar lf-typeahead-avatar-ph"></span>';
        return '<div class="lf-typeahead-item' + (i === selected ? ' active' : '') +
          '" data-i="' + i + '" role="option">' + av +
          '<div class="lf-typeahead-text"><span class="lf-typeahead-handle">@' + escapeAttr(a.handle) + '</span>' + dn + '</div>' +
          '</div>';
      }).join('');
      dropdown.classList.toggle('open', items.length > 0);
      // attach a long-press / right-click menu to each rendered item
      dropdown.querySelectorAll('.lf-typeahead-item').forEach(function(el, i) {
        bindContextMenu(el, function() {
          var a = items[i];
          return authorMenuItems(a.handle, a.did);
        });
      });
    }

    function pick(idx) {
      var a = items[idx];
      var info = matchInfo;
      if (!a || !info) return;
      var v = input.value;
      input.value = v.slice(0, info.start) + '@' + a.handle + ' ' + v.slice(info.end);
      hide();
      if (opts.onPick) opts.onPick(a);
    }

    function maybeFetch() {
      var info = findHandlePartial();
      matchInfo = info;
      if (!info || info.partial.length < 1) { hide(); return; }
      if (info.partial === lastFetched) return;
      lastFetched = info.partial;
      var query = info.partial;
      fetch(TYPEAHEAD_BASE + '/xrpc/app.bsky.actor.searchActorsTypeahead?q=' +
        encodeURIComponent(query) + '&limit=' + LIMIT,
        { headers: { 'X-Client': 'pub-search.waow.tech' } })
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(d) {
          if (!d || !matchInfo || matchInfo.partial !== query) return;
          items = (d.actors || []).slice(0, LIMIT);
          selected = items.length > 0 ? 0 : -1;
          render();
        })
        .catch(function() {});
    }

    input.addEventListener('input', function() {
      if (timer) clearTimeout(timer);
      timer = setTimeout(maybeFetch, DEBOUNCE_MS);
    });

    input.addEventListener('keydown', function(e) {
      if (!dropdown.classList.contains('open')) return;
      if (e.key === 'ArrowDown') {
        e.preventDefault(); selected = (selected + 1) % items.length; render();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault(); selected = (selected - 1 + items.length) % items.length; render();
      } else if (e.key === 'Enter') {
        e.preventDefault(); e.stopImmediatePropagation(); pick(selected);
      } else if (e.key === 'Escape') {
        e.preventDefault(); e.stopImmediatePropagation(); hide();
      } else if (e.key === 'Tab') {
        pick(selected);
      }
    });

    // mousedown picks on pointer devices (fires before blur so we don't lose
    // the click). touch devices fall back to click since touch doesn't
    // fire mousedown reliably before blur on iOS.
    dropdown.addEventListener('mousedown', function(e) {
      var t = e.target.closest('.lf-typeahead-item');
      if (!t) return;
      e.preventDefault();
      pick(parseInt(t.getAttribute('data-i'), 10));
    });
    dropdown.addEventListener('click', function(e) {
      var t = e.target.closest('.lf-typeahead-item');
      if (!t) return;
      pick(parseInt(t.getAttribute('data-i'), 10));
    });

    document.addEventListener('click', function(e) {
      if (!input.contains(e.target) && !dropdown.contains(e.target)) hide();
    });

    input.addEventListener('blur', function() {
      setTimeout(hide, 150);
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
    curatorMenuItems: curatorMenuItems,
    isMobile: isMobile,
  };
})();
