// LeafletIdentity — batch DID/handle → profile resolution against typeahead,
// the community-run drop-in replacement for app.bsky.actor.getProfiles. We
// route here instead of hitting bsky directly so we're not contributing to
// public.api.bsky.app's load for what's effectively a cacheable identity
// lookup, and so we stay inside the microcosm/atproto-native stack.
//
// Live: https://typeahead.waow.tech (source: ../typeahead in this org)
//
// Usage:
//   var ids = await window.LeafletIdentity.resolveProfiles([did1, did2, ...]);
//   ids.get(did1) // → { did, handle, displayName?, avatar?, ... } or undefined
(function () {
  var BASE = 'https://typeahead.waow.tech';
  var MAX_PER_CALL = 25; // matches the upstream lexicon's cap

  // Module-level memo so repeated lookups for the same actor across a page
  // life don't refetch. Keyed by the input string (did or handle).
  var cache = new Map();

  function resolveProfiles(actors) {
    if (!actors || actors.length === 0) return Promise.resolve(new Map());

    var out = new Map();
    var missing = [];
    actors.forEach(function (a) {
      if (!a) return;
      if (cache.has(a)) {
        var p = cache.get(a);
        if (p) out.set(a, p);
      } else {
        missing.push(a);
      }
    });
    if (missing.length === 0) return Promise.resolve(out);

    // dedupe; bsky's getProfiles caps at 25/call
    var unique = Array.from(new Set(missing));
    var chunks = [];
    for (var i = 0; i < unique.length; i += MAX_PER_CALL) {
      chunks.push(unique.slice(i, i + MAX_PER_CALL));
    }

    return Promise.all(chunks.map(function (chunk) {
      var qs = chunk.map(function (a) { return 'actors=' + encodeURIComponent(a); }).join('&');
      return fetch(BASE + '/xrpc/app.bsky.actor.getProfiles?' + qs,
        { headers: { 'X-Client': 'pub-search.waow.tech' } })
        .then(function (r) { return r.ok ? r.json() : null; })
        .catch(function () { return null; });
    })).then(function (results) {
      results.forEach(function (d) {
        if (!d || !Array.isArray(d.profiles)) return;
        d.profiles.forEach(function (p) {
          if (!p) return;
          // index by both DID and handle so callers using either form hit
          // the cache on subsequent calls without another network round-trip.
          if (p.did) cache.set(p.did, p);
          if (p.handle) cache.set(p.handle, p);
          if (p.did) out.set(p.did, p);
          if (p.handle) out.set(p.handle, p);
        });
      });
      // negative cache: actors we asked about but didn't get back stay
      // out of cache so a later call can retry (handle resolution sometimes
      // races with the ingester).
      return out;
    });
  }

  function resolveProfile(actor) {
    return resolveProfiles([actor]).then(function (m) { return m.get(actor) || null; });
  }

  window.LeafletIdentity = {
    resolveProfiles: resolveProfiles,
    resolveProfile: resolveProfile,
  };
})();
