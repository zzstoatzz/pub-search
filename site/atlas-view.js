(function(root) {
  'use strict';
  // atlas-view.json.gz is atlas.json.gz re-laid as columns (scripts/atlas_view.py).
  // decode rebuilds the atlas.json shape, in the map's original point order.
  var RKEY = '\x01';
  function decode(view) {
    if (!view || view.version !== 1 || !view.points || !Array.isArray(view.points.index)) throw Error('Unknown Atlas view.');
    var c = view.points, n = c.index.length, points = new Array(n);
    for (var name of ['x','y','platform','did','collection','rkey','basePath','title','path','clusterCoarse','clusterFine']) {
      if (!Array.isArray(c[name]) || c[name].length !== n) throw Error('Atlas view columns disagree.');
    }
    for (var k = 0; k < n; k++) {
      var rkey = c.rkey[k], i = c.index[k];
      if (!Number.isInteger(i) || i < 0 || i >= n || points[i]) throw Error('Atlas view order is not a permutation.');
      points[i] = {
        x: c.x[k] / 10000,
        y: c.y[k] / 10000,
        uri: 'at://' + view.dids[c.did[k]] + '/' + view.collections[c.collection[k]] + '/' + rkey,
        title: c.title[k],
        platform: view.platforms[c.platform[k]],
        basePath: view.basePaths[c.basePath[k]],
        path: c.path[k].split(RKEY).join(rkey),
        clusterCoarse: c.clusterCoarse[k],
        clusterFine: c.clusterFine[k],
      };
    }
    return {points: points, clusters: view.clusters, publications: view.publications, meta: view.meta};
  }
  function gunzipJson(response) {
    if (!response.ok) throw Error('Map download failed (' + response.status + ').');
    return new Response(response.body.pipeThrough(new DecompressionStream('gzip'))).json();
  }
  // the columnar view when it is there and sound, otherwise the full atlas.json.gz
  function load(pending) {
    return (pending || fetch('atlas-view.json.gz')).then(gunzipJson).then(decode).catch(function() {
      return fetch('atlas.json.gz').then(gunzipJson);
    });
  }
  root.AtlasView = {decode: decode, load: load};
})(typeof window === 'undefined' ? globalThis : window);
