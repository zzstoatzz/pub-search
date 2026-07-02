// the single frontend registry of publishing platforms pub-search presents.
// Adding a platform (e.g. lemma) = one entry here (+ a backend detection rule
// in ingest/extractor.zig if it isn't classified yet — new platforms show up
// as 'other' until then). Everything else — filter pills, the homepage
// marquee, atlas colors/legend/logos, home links — derives from this.
(function () {
  var ORDER = ['leaflet', 'whitewind', 'pckt', 'offprint', 'greengale', 'lemma', 'other'];

  var BY_ID = {
    leaflet:   { domain: 'leaflet.pub',   dark: { core: '#4ade80', mid: '#22c55e', edge: '#166534' }, light: { core: '#16a34a', mid: '#15803d', edge: '#a7f3d0' } },
    whitewind: { domain: 'whtwnd.com',    dark: { core: '#60a5fa', mid: '#3b82f6', edge: '#1e3a8a' }, light: { core: '#2563eb', mid: '#1d4ed8', edge: '#bfdbfe' } },
    pckt:      { domain: 'pckt.blog',     dark: { core: '#fbbf24', mid: '#f59e0b', edge: '#92400e' }, light: { core: '#d97706', mid: '#b45309', edge: '#fde68a' } },
    offprint:  { domain: 'offprint.app',  dark: { core: '#fb7185', mid: '#f43f5e', edge: '#881337' }, light: { core: '#e11d48', mid: '#be123c', edge: '#fecdd3' } },
    greengale: { domain: 'greengale.app', dark: { core: '#2dd4bf', mid: '#14b8a6', edge: '#134e4a' }, light: { core: '#0d9488', mid: '#0f766e', edge: '#99f6e4' } },
    lemma:     { domain: 'lemma.pub',     dark: { core: '#c084fc', mid: '#a855f7', edge: '#581c87' }, light: { core: '#9333ea', mid: '#7e22ce', edge: '#e9d5ff' } },
    other:     { domain: null,            dark: { core: '#9ca3af', mid: '#6b7280', edge: '#374151' }, light: { core: '#4b5563', mid: '#374151', edge: '#d1d5db' } },
  };

  window.PubPlatforms = {
    order: ORDER,
    byId: BY_ID,
    domainOf: function (id) { return (BY_ID[id] || {}).domain || null; },
    homeOf: function (id) {
      var d = this.domainOf(id);
      return d ? 'https://' + d : 'https://standard.site';
    },
    labelOf: function (id) { return this.domainOf(id) || 'other'; },
    iconUrl: function (id) {
      var d = this.domainOf(id);
      return d ? 'https://icons.duckduckgo.com/ip3/' + d + '.ico' : null;
    },
    colors: function (theme) {
      var out = {};
      for (var i = 0; i < ORDER.length; i++) out[ORDER[i]] = BY_ID[ORDER[i]][theme === 'light' ? 'light' : 'dark'];
      return out;
    },
    // platforms with real homes (marquee etc.) — everything but 'other'
    named: function () {
      return ORDER.filter(function (id) { return BY_ID[id].domain; });
    },
  };
})();
