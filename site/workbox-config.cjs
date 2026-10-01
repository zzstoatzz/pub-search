module.exports = {
  globDirectory: '.',
  globPatterns: [
    '*.html',
    '*.css',
    '*.js',
    'icons/*.png',
    'platforms/*',
    'favicon.svg',
    'manifest.webmanifest',
    'facts.json',
  ],
  globIgnores: ['sw.js', 'sw-atlas-refresh.js', 'atlas.html', 'workbox-*.js', 'workbox-config.cjs'],
  importScripts: ['sw-atlas-refresh.js'],
  manifestTransforms: [async entries => ({
    manifest: entries.map(entry => ['atlas.css', 'atlas.js', 'atlas-summaries.js', 'atlas-finder.js'].includes(entry.url)
      ? { ...entry, url: entry.url + '?build=polish-5' } : entry),
    warnings: [],
  })],
  swDest: 'sw.js',
  sourcemap: false,
  skipWaiting: true,
  clientsClaim: true,
  cleanupOutdatedCaches: true,
  // pages reference css/js with ?v= cache-busters; match them to the precache
  ignoreURLParametersMatching: [/^v$/],
  runtimeCaching: [
    {
      urlPattern: ({ request, url }) => request.mode === 'navigate' && /^\/atlas(?:\.html)?\/?$/.test(url.pathname),
      handler: 'NetworkFirst',
      options: { cacheName: 'atlas-page', networkTimeoutSeconds: 10, expiration: { maxEntries: 4 } },
    },
    {
      urlPattern: /\/atlas\.json\.gz$/,
      handler: 'NetworkFirst',
      options: { cacheName: 'atlas-map', networkTimeoutSeconds: 10, expiration: { maxEntries: 2 } },
    },
    {
      // atlas datasets are big (atlas.json ~7MB) and rebuilt every 6h — serve
      // cached instantly, refresh in the background
      urlPattern: /\/atlas(-mini|-avatar-cache|-theme-cache)\.json(\.gz)?$/,
      handler: 'StaleWhileRevalidate',
      options: {
        cacheName: 'atlas-data',
        expiration: { maxEntries: 8 },
      },
    },
  ],
}
