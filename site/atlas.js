(function() {
  'use strict';

  var PLATFORM_COLORS = {
    leaflet:   { core: '#4ade80', mid: '#22c55e', edge: '#166534' },
    whitewind: { core: '#60a5fa', mid: '#3b82f6', edge: '#1e3a8a' },
    pckt:      { core: '#fbbf24', mid: '#f59e0b', edge: '#92400e' },
    offprint:  { core: '#fb7185', mid: '#f43f5e', edge: '#881337' },
    greengale: { core: '#2dd4bf', mid: '#14b8a6', edge: '#134e4a' },
    other:     { core: '#9ca3af', mid: '#6b7280', edge: '#374151' },
  };

  var PLATFORM_COLORS_LIGHT = {
    leaflet:   { core: '#16a34a', mid: '#15803d', edge: '#a7f3d0' },
    whitewind: { core: '#2563eb', mid: '#1d4ed8', edge: '#bfdbfe' },
    pckt:      { core: '#d97706', mid: '#b45309', edge: '#fde68a' },
    offprint:  { core: '#e11d48', mid: '#be123c', edge: '#fecdd3' },
    greengale: { core: '#0d9488', mid: '#0f766e', edge: '#99f6e4' },
    other:     { core: '#4b5563', mid: '#374151', edge: '#d1d5db' },
  };

  var PLATFORMS = ['leaflet', 'whitewind', 'pckt', 'offprint', 'greengale', 'other'];

  // --- precomputed color cache (rebuilt once per frame) ---
  var frameColors = null; // current platform colors object
  var frameDark = true;   // current theme
  var frameRgba = null;   // { platform: { core_XX: 'rgba(...)' } } — precomputed rgba strings

  function parseHex(hex) {
    return [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)];
  }

  // build all rgba strings we'll need this frame
  function cacheFrameColors() {
    var dark = document.documentElement.getAttribute('data-theme') !== 'light';
    frameDark = dark;
    frameColors = dark ? PLATFORM_COLORS : PLATFORM_COLORS_LIGHT;
    frameRgba = {};
    var alphas = [0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.12, 0.14, 0.18, 0.25, 0.40, 0.70, 1.0];
    for (var p = 0; p < PLATFORMS.length; p++) {
      var name = PLATFORMS[p];
      var c = frameColors[name];
      var entry = {};
      var parts = { core: parseHex(c.core), mid: parseHex(c.mid), edge: parseHex(c.edge) };
      for (var key in parts) {
        var rgb = parts[key];
        for (var a = 0; a < alphas.length; a++) {
          entry[key + '_' + alphas[a]] = 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + alphas[a] + ')';
        }
      }
      frameRgba[name] = entry;
    }
  }

  function hexToRgba(hex, a) {
    var r = parseInt(hex.slice(1, 3), 16);
    var g = parseInt(hex.slice(3, 5), 16);
    var b = parseInt(hex.slice(5, 7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + a + ')';
  }

  // --- view state ---
  // maxZoom 500 (was 60): past zoom ~45 each document grows into a card
  // (platform, wrapped title, publication avatar) that keeps upsizing as
  // you approach — see the document-card layer in render(). the extra
  // headroom past the card's full size (~250) is for separating docs that
  // sit nearly on top of each other in dense clusters.
  var view = { zoom: 1, panX: 0, panY: 0, minZoom: 0.5, maxZoom: 500, dirty: true };

  // --- demand-driven frame scheduling ---
  var frameRequested = false;

  function scheduleFrame() {
    if (!frameRequested) {
      frameRequested = true;
      requestAnimationFrame(loop);
    }
  }

  function markDirty() {
    view.dirty = true;
    scheduleFrame();
  }

  // --- data ---
  var data = null;
  var pointsX = null;
  var pointsY = null;
  var platformIdx = null;
  var gridIndex = null;
  var uriToIndex = null; // Map<uri, index> for search matching
  var clusterFineArr = null; // Uint8Array of fine cluster IDs per point

  // --- publication state ---
  var pubData = null; // array from atlas.json
  var pubByBasePath = null; // Map<basePath, pub> for ?pub=<basePath> deep-links

  // platform logos — drawn next to per-doc titles at high zoom for identity.
  // We snagged the best-available icon per platform (apple-touch-icon /
  // favicon.svg / favicon.ico → png). See site/platforms/.
  var platformLogos = {};
  var PLATFORM_LOGO_EXT = {
    leaflet: 'png',
    whitewind: 'svg',
    pckt: 'png',
    offprint: 'svg',
    greengale: 'png',
    other: 'png',
  };
  function loadPlatformLogos() {
    Object.keys(PLATFORM_LOGO_EXT).forEach(function(p) {
      if (platformLogos[p]) return;
      var img = new Image();
      img.onload = function() { markDirty(); };
      img.onerror = function() { platformLogos[p] = null; };
      img.src = '/platforms/' + p + '.' + PLATFORM_LOGO_EXT[p];
      platformLogos[p] = img;
    });
  }

  var pubImages = {}; // basePath → HTMLImageElement (loaded)
  var pubFailed = {}; // basePath → true (failed to load)
  var pubLoading = {}; // basePath → true (currently loading)
  var PUB_MAX_CONCURRENT = 6;
  var pubLoadCount = 0;

  function pubImageUrl(pub) {
    // prefer cover image, fall back to author avatar
    if (pub.did && pub.coverImage) {
      return 'https://cdn.bsky.app/img/feed_thumbnail/plain/' + pub.did + '/' + pub.coverImage + '@jpeg';
    }
    if (pub.avatar) return pub.avatar;
    return null;
  }

  function loadPubImage(pub) {
    var key = pub.basePath;
    if (pubImages[key] || pubFailed[key] || pubLoading[key]) return;
    if (pubLoadCount >= PUB_MAX_CONCURRENT) return;
    var url = pubImageUrl(pub);
    if (!url) { pubFailed[key] = true; return; }
    pubLoading[key] = true;
    pubLoadCount++;
    var img = new Image();
    img.onload = function() {
      pubImages[key] = img;
      delete pubLoading[key];
      pubLoadCount--;
      markDirty();
    };
    img.onerror = function() {
      pubFailed[key] = true;
      delete pubLoading[key];
      pubLoadCount--;
    };
    img.src = url;
  }

  // --- search state ---
  var searchMatches = null; // Set of point indices matching current search
  var searchCenter = null; // {x, y} weighted centroid of matches
  var searchQuery = '';

  // --- animation state ---
  var animating = false;
  var animFrom = null;
  var animTo = null;
  var animStart = 0;
  var ANIM_DURATION = 600; // ms

  // --- canvas ---
  var canvas = document.getElementById('canvas');
  var ctx = canvas.getContext('2d');
  var dpr = window.devicePixelRatio || 1;
  var W, H;

  // --- sprite cache ---
  var sprites = null;
  var spriteSize = 0;
  var spriteTheme = null;

  function buildSprites(radius) {
    // quantize radius to 0.5px steps to avoid rebuilding during smooth zoom
    radius = Math.round(radius * 2) / 2;
    var size = Math.ceil(radius * 6 * dpr) + 2;
    if (size < 4) size = 4;
    var theme = frameDark ? 'dark' : 'light';
    if (sprites && spriteSize === size && spriteTheme === theme) return;
    spriteSize = size;
    spriteTheme = theme;
    sprites = [];
    for (var p = 0; p < PLATFORMS.length; p++) {
      var c = frameColors[PLATFORMS[p]];
      sprites.push({
        normal: makeSprite(size, radius * dpr, c, 0.7),
        hover:  makeSprite(size * 2, radius * dpr * 2, c, 1.0),
      });
    }
  }

  function makeSprite(size, r, colors, alpha) {
    var cv = document.createElement('canvas');
    cv.width = size; cv.height = size;
    var c = cv.getContext('2d');
    var half = size / 2;
    var grad = c.createRadialGradient(half, half, 0, half, half, r * 2.5);
    grad.addColorStop(0, colors.core);
    grad.addColorStop(0.3, colors.mid);
    grad.addColorStop(0.7, colors.edge);
    grad.addColorStop(1, 'rgba(0,0,0,0)');
    c.globalAlpha = alpha;
    c.fillStyle = grad;
    c.beginPath();
    c.arc(half, half, r * 2.5, 0, Math.PI * 2);
    c.fill();
    c.globalAlpha = alpha * 0.9;
    c.fillStyle = colors.core;
    c.beginPath();
    c.arc(half, half, r * 0.5, 0, Math.PI * 2);
    c.fill();
    return cv;
  }

  var dotSprites = null;
  var dotTheme = null;

  function buildDotSprites() {
    var theme = frameDark ? 'dark' : 'light';
    if (dotSprites && dotTheme === theme) return;
    dotTheme = theme;
    dotSprites = [];
    var s = Math.max(4, Math.ceil(3 * dpr));
    for (var p = 0; p < PLATFORMS.length; p++) {
      var cv = document.createElement('canvas');
      cv.width = s; cv.height = s;
      var c = cv.getContext('2d');
      c.fillStyle = frameColors[PLATFORMS[p]].mid;
      c.globalAlpha = 0.7;
      c.beginPath();
      c.arc(s / 2, s / 2, s / 2, 0, Math.PI * 2);
      c.fill();
      dotSprites.push(cv);
    }
  }

  // --- nebula halo sprite cache ---
  var haloSprites = null; // { theme, entries: { 'platform_bucket': canvas } }
  var HALO_BUCKETS = [20, 50, 100, 200, 400]; // radius pixel buckets

  function getHaloBucket(radiusPx) {
    for (var i = 0; i < HALO_BUCKETS.length; i++) {
      if (radiusPx <= HALO_BUCKETS[i]) return HALO_BUCKETS[i];
    }
    return HALO_BUCKETS[HALO_BUCKETS.length - 1];
  }

  function buildHaloSprite(platform, bucket) {
    var size = bucket * 2 + 4;
    var cv = document.createElement('canvas');
    cv.width = size; cv.height = size;
    var c = cv.getContext('2d');
    var half = size / 2;
    var nc = frameColors[platform];
    var grad = c.createRadialGradient(half, half, 0, half, half, bucket);
    grad.addColorStop(0, hexToRgba(nc.core, 1));
    grad.addColorStop(0.3, hexToRgba(nc.mid, 0.5));
    grad.addColorStop(0.7, hexToRgba(nc.edge, 0.2));
    grad.addColorStop(1, 'rgba(0,0,0,0)');
    c.fillStyle = grad;
    c.beginPath();
    c.arc(half, half, bucket, 0, Math.PI * 2);
    c.fill();
    return cv;
  }

  function getHaloSprite(platform, radiusPx) {
    var theme = frameDark ? 'dark' : 'light';
    if (!haloSprites || haloSprites.theme !== theme) {
      haloSprites = { theme: theme, entries: {} };
    }
    var bucket = getHaloBucket(radiusPx);
    var key = platform + '_' + bucket;
    if (!haloSprites.entries[key]) {
      haloSprites.entries[key] = buildHaloSprite(platform, bucket);
    }
    return { sprite: haloSprites.entries[key], bucket: bucket };
  }

  function resizeCanvas() {
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    sprites = null;
    dotSprites = null;
    haloSprites = null;
    markDirty();
  }

  // --- coordinate transforms (inlined for hot path) ---
  var scale = 1; // cached per frame
  var cx, cy;

  function cacheTransform() {
    scale = Math.min(W, H) * 0.42 * view.zoom;
    cx = W / 2 + view.panX * scale;
    cy = H / 2 + view.panY * scale;
  }

  function screenToData(sx, sy) {
    return [(sx - W / 2) / scale - view.panX, (sy - H / 2) / scale - view.panY];
  }

  // --- spatial index ---
  function buildSpatialIndex() {
    if (!data) return;
    var cellSize = 0.02;
    gridIndex = { cellSize: cellSize, cells: {} };
    for (var i = 0; i < data.points.length; i++) {
      var key = Math.floor(pointsX[i] / cellSize) + ',' + Math.floor(pointsY[i] / cellSize);
      if (!gridIndex.cells[key]) gridIndex.cells[key] = [];
      gridIndex.cells[key].push(i);
    }
  }

  function findNearest(sx, sy, maxDist) {
    if (!gridIndex) return -1;
    var d = screenToData(sx, sy);
    var dx = d[0], dy = d[1];
    var searchRadius = maxDist / scale;
    var cs = gridIndex.cellSize;
    var gxMin = Math.floor((dx - searchRadius) / cs);
    var gxMax = Math.floor((dx + searchRadius) / cs);
    var gyMin = Math.floor((dy - searchRadius) / cs);
    var gyMax = Math.floor((dy + searchRadius) / cs);
    var bestIdx = -1, bestDist = searchRadius * searchRadius;
    for (var gx = gxMin; gx <= gxMax; gx++) {
      for (var gy = gyMin; gy <= gyMax; gy++) {
        var cell = gridIndex.cells[gx + ',' + gy];
        if (!cell) continue;
        for (var k = 0; k < cell.length; k++) {
          var i = cell[k];
          var ddx = pointsX[i] - dx, ddy = pointsY[i] - dy;
          var dist2 = ddx * ddx + ddy * ddy;
          if (dist2 < bestDist) { bestDist = dist2; bestIdx = i; }
        }
      }
    }
    return bestIdx;
  }

  // --- document cards (high-zoom close-up view) ---
  // crossfade from bare title labels into cards over CARD_START..CARD_START+CARD_RANGE;
  // cards then keep growing ("HD") until zoom CARD_FULL.
  var CARD_START = 45, CARD_RANGE = 20, CARD_FULL = 250;
  var cardHitRects = null; // [{x, y, w, h, i}] rebuilt each frame, for hover/click

  function findCardAt(sx, sy) {
    if (!cardHitRects) return -1;
    for (var k = cardHitRects.length - 1; k >= 0; k--) {
      var r = cardHitRects[k];
      if (sx >= r.x && sx <= r.x + r.w && sy >= r.y && sy <= r.y + r.h) return r.i;
    }
    return -1;
  }

  function roundRectPath(x, y, w, h, r) {
    ctx.beginPath();
    if (ctx.roundRect) { ctx.roundRect(x, y, w, h, r); return; }
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // monospace word-wrap: returns up to maxLines lines, ellipsis on overflow.
  // hard-breaks long unbroken runs (URLs, CJK) so nothing escapes the card.
  function wrapText(text, maxW, maxLines) {
    var charW = ctx.measureText('M').width || 7;
    var maxChars = Math.max(4, Math.floor(maxW / charW));
    var words = text.split(/\s+/);
    var lines = [], cur = '', truncated = false;
    for (var w = 0; w < words.length; w++) {
      var word = words[w];
      while (word.length > maxChars && lines.length < maxLines) {
        if (cur) { lines.push(cur); cur = ''; }
        if (lines.length >= maxLines) break;
        lines.push(word.slice(0, maxChars));
        word = word.slice(maxChars);
      }
      if (lines.length >= maxLines) { truncated = true; break; }
      var attempt = cur ? cur + ' ' + word : word;
      if (attempt.length > maxChars) {
        lines.push(cur);
        cur = word;
        if (lines.length >= maxLines) { truncated = true; break; }
      } else {
        cur = attempt;
      }
    }
    if (cur && lines.length < maxLines) lines.push(cur);
    else if (cur) truncated = true;
    if (truncated && lines.length > 0) {
      var last = lines[lines.length - 1];
      if (last.length >= maxChars) last = last.slice(0, maxChars - 1);
      lines[lines.length - 1] = last + '…';
    }
    return lines;
  }

  function truncToChars(text, maxW) {
    var charW = ctx.measureText('M').width || 7;
    var maxChars = Math.max(4, Math.floor(maxW / charW));
    if (text.length <= maxChars) return text;
    return text.slice(0, maxChars - 1) + '…';
  }

  // --- label helper: strokeText outline instead of shadowBlur ---
  function drawLabel(text, x, y, dark) {
    ctx.strokeStyle = dark ? 'rgba(0,0,0,0.7)' : 'rgba(255,255,255,0.7)';
    ctx.lineWidth = 3;
    ctx.lineJoin = 'round';
    ctx.strokeText(text, x, y);
    ctx.fillText(text, x, y);
  }

  // --- smooth transition helpers ---
  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function fadeIn(zoom, start, range) { return clamp01((zoom - start) / range); }
  function fadeOut(zoom, start, range) { return 1 - clamp01((zoom - start) / range); }

  // --- connection line buffers (pre-allocated, reused each frame) ---
  var connBufSize = 6000;
  var connBufs = null; // [platform][bucket] = Float32Array
  var connBufLens = null; // [platform][bucket] = current length

  function initConnBuffers() {
    connBufs = [];
    connBufLens = [];
    for (var p = 0; p < PLATFORMS.length; p++) {
      connBufs.push([
        new Float32Array(connBufSize),
        new Float32Array(connBufSize),
        new Float32Array(connBufSize)
      ]);
      connBufLens.push([0, 0, 0]);
    }
  }

  function resetConnBuffers() {
    for (var p = 0; p < PLATFORMS.length; p++) {
      connBufLens[p][0] = 0;
      connBufLens[p][1] = 0;
      connBufLens[p][2] = 0;
    }
  }

  // --- rendering ---
  function render() {
    if (!data || !view.dirty) return;
    view.dirty = false;

    // cache theme + colors once per frame
    cacheFrameColors();
    var dark = frameDark;
    var zoom = view.zoom;
    var n = data.points.length;

    cacheTransform();

    // background
    ctx.globalAlpha = 1;
    ctx.fillStyle = dark ? '#050505' : '#f5f5f0';
    ctx.fillRect(0, 0, W, H);

    // visible bounds in data space
    var tl = screenToData(0, 0);
    var br = screenToData(W, H);
    var pad = 0.05;
    var xMin = tl[0] - pad, xMax = br[0] + pad;
    var yMin = tl[1] - pad, yMax = br[1] + pad;

    // --- cluster nebula halos (colored by dominant platform) ---
    // continuous alpha curve: full at zoom<2, fades gradually past zoom 2.
    // mobile (W<600): floor drops 25%→10% AND sprite scaled to 60% so the
    // glow doesn't drown the rest of the map on a small screen.
    var smallViewport = W < 600;
    var haloFloor = smallViewport ? 0.10 : 0.25;
    var haloShrink = smallViewport ? 0.6 : 1.0;
    var haloAlphaFactor = zoom < 2 ? 1.0 : Math.max(haloFloor, 1 - (zoom - 2) / 8);
    // at card zoom the nebulae are just backdrop noise — fade them out
    haloAlphaFactor *= fadeOut(zoom, 30, 20);
    if (haloAlphaFactor > 0.01) {
      var clusters = zoom < 2 ? data.clusters.coarse : data.clusters.fine;
      var baseAlpha = dark ? (zoom < 2 ? 0.06 : 0.04) : (zoom < 2 ? 0.05 : 0.03);
      baseAlpha *= haloAlphaFactor;
      for (var c = 0; c < clusters.length; c++) {
        var cl = clusters[c];
        var r = (cl.radius || 0.05) * scale;
        if (r < 2) continue;
        var sx = cx + cl.cx * scale, sy = cy + cl.cy * scale;
        if (sx + r < 0 || sx - r > W || sy + r < 0 || sy - r > H) continue;
        var platform = cl.dominantPlatform || 'other';
        var halo = getHaloSprite(platform, r);
        var spriteScale = r / halo.bucket;
        var drawSize = halo.sprite.width * spriteScale * haloShrink;
        ctx.globalAlpha = baseAlpha * 2; // match original: gradient center was baseAlpha*2
        ctx.drawImage(halo.sprite, sx - drawSize / 2, sy - drawSize / 2, drawSize, drawSize);
      }
    }

    // --- connection lines (intra-cluster, colored by platform) ---
    // smooth fade-in over zoom 2.5–3.5
    var connAlphaFactor = fadeIn(zoom, 2.5, 1.0);
    if (connAlphaFactor > 0 && gridIndex && clusterFineArr) {
      if (!connBufs) initConnBuffers();
      resetConnBuffers();

      var connRadius = 0.025;
      var cs = gridIndex.cellSize;
      var maxLines = 1500;
      var lineCount = 0;

      for (var i = 0; i < n && lineCount < maxLines; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;

        var sx1 = cx + px * scale, sy1 = cy + py * scale;
        var ci = clusterFineArr[i];
        var gxMin2 = Math.floor((px - connRadius) / cs);
        var gxMax2 = Math.floor((px + connRadius) / cs);
        var gyMin2 = Math.floor((py - connRadius) / cs);
        var gyMax2 = Math.floor((py + connRadius) / cs);

        for (var gx = gxMin2; gx <= gxMax2 && lineCount < maxLines; gx++) {
          for (var gy = gyMin2; gy <= gyMax2 && lineCount < maxLines; gy++) {
            var cell = gridIndex.cells[gx + ',' + gy];
            if (!cell) continue;
            for (var k = 0; k < cell.length && lineCount < maxLines; k++) {
              var j = cell[k];
              if (j <= i) continue;
              if (clusterFineArr[j] !== ci) continue;
              var dx = pointsX[j] - px, dy = pointsY[j] - py;
              var dist2 = dx * dx + dy * dy;
              if (dist2 > connRadius * connRadius || dist2 < 0.0001) continue;
              var t = Math.sqrt(dist2) / connRadius;
              var bucket = t < 0.33 ? 0 : t < 0.66 ? 1 : 2;
              var pi = platformIdx[i];
              var buf = connBufs[pi][bucket];
              var len = connBufLens[pi][bucket];
              if (len + 4 <= buf.length) {
                buf[len] = sx1;
                buf[len + 1] = sy1;
                buf[len + 2] = cx + pointsX[j] * scale;
                buf[len + 3] = cy + pointsY[j] * scale;
                connBufLens[pi][bucket] = len + 4;
              }
              lineCount++;
            }
          }
        }
      }

      // draw each platform × distance bucket
      var connAlphas = dark ? [0.18, 0.10, 0.05] : [0.14, 0.08, 0.03];
      ctx.lineWidth = 0.5;
      for (var p = 0; p < PLATFORMS.length; p++) {
        var cc = frameColors[PLATFORMS[p]];
        for (var b = 0; b < 3; b++) {
          var len = connBufLens[p][b];
          if (!len) continue;
          var buf = connBufs[p][b];
          ctx.beginPath();
          for (var l = 0; l < len; l += 4) {
            ctx.moveTo(buf[l], buf[l + 1]);
            ctx.lineTo(buf[l + 2], buf[l + 3]);
          }
          ctx.strokeStyle = hexToRgba(cc.mid, connAlphas[b] * connAlphaFactor);
          ctx.globalAlpha = 1;
          ctx.stroke();
        }
      }
    }

    // --- publication circles ---
    // radius = sqrt(count) * zoom * 0.35, capped at 28px
    // at zoom 1: sqrt(236)≈15 → 5.4px (visible), sqrt(30)≈5.5 → 1.9px (culled)
    // smaller than before — publications accent the map, not dominate it
    if (pubData && pubData.length > 0) {
      var pubLabelZoom = 3;
      var pubRendered = 0;
      for (var pi2 = 0; pi2 < pubData.length; pi2++) {
        var pub = pubData[pi2];
        var pr = Math.min(28, Math.sqrt(pub.count) * zoom * 0.35);
        if (pr < 4) continue; // natural culling — small pubs disappear
        var psx = cx + pub.cx * scale, psy = cy + pub.cy * scale;
        // cull off-screen (with padding for labels)
        if (psx < -60 || psx > W + 60 || psy < -60 || psy > H + 60) continue;
        pubRendered++;
        var pPlatform = pub.platform || 'other';
        var pColors = frameColors[pPlatform] || frameColors.other;

        // lazy-load image for visible, large-enough publications
        if (pr >= 12) loadPubImage(pub);

        var img = pubImages[pub.basePath];
        if (img) {
          // clipped circle with cover image
          ctx.save();
          ctx.globalAlpha = 0.9;
          ctx.beginPath();
          ctx.arc(psx, psy, pr, 0, Math.PI * 2);
          ctx.clip();
          ctx.drawImage(img, psx - pr, psy - pr, pr * 2, pr * 2);
          ctx.restore();
        } else {
          // fallback: filled circle with first letter
          ctx.globalAlpha = 0.7;
          ctx.beginPath();
          ctx.arc(psx, psy, pr, 0, Math.PI * 2);
          ctx.fillStyle = pColors.edge;
          ctx.fill();
          // letter only when circle is large enough to read
          if (pr >= 10) {
            var letter = (pub.name || '?').charAt(0).toUpperCase();
            var letterSize = Math.max(8, pr * 0.9);
            ctx.font = 'bold ' + Math.round(letterSize) + 'px monospace';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillStyle = pColors.core;
            ctx.globalAlpha = 0.9;
            ctx.fillText(letter, psx, psy);
          }
        }

        // border ring
        ctx.globalAlpha = 0.6;
        ctx.beginPath();
        ctx.arc(psx, psy, pr, 0, Math.PI * 2);
        ctx.strokeStyle = pColors.mid;
        ctx.lineWidth = 1.5;
        ctx.stroke();

        // name label at higher zoom
        if (zoom >= pubLabelZoom && pr >= 10) {
          var labelSize = Math.max(8, Math.min(12, pr * 0.5));
          ctx.font = Math.round(labelSize) + 'px monospace';
          ctx.textAlign = 'center';
          ctx.textBaseline = 'top';
          ctx.globalAlpha = Math.min(0.8, fadeIn(zoom, pubLabelZoom, 1.0));
          ctx.fillStyle = dark ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.75)';
          var pubLabel = pub.name.length > 20 ? pub.name.substring(0, 18) + '\u2026' : pub.name;
          drawLabel(pubLabel, psx, psy + pr + 4, dark);
        }
      }
      ctx.globalAlpha = 1;
    }

    // --- points: sprite-stamped ---
    ctx.globalAlpha = 1;
    var useGlow = zoom >= 2;
    if (useGlow) {
      // dot radius grows with zoom but caps at 7px so the sprite atlas
      // doesn't balloon when zoom passes ~25. Past the cap, dots stay
      // legible without becoming the focus — titles / icons take over.
      var pointR = zoom < 5 ? 1.5 + zoom * 0.3 : Math.min(7, 2 + zoom * 0.2);
      buildSprites(pointR);
    } else {
      buildDotSprites();
    }

    var filtering = activePlatforms !== null;
    // draw dimmed points first, then active points on top
    for (var pass = 0; pass < (filtering ? 2 : 1); pass++) {
      if (filtering && pass === 0) ctx.globalAlpha = 0.12;
      else ctx.globalAlpha = 1;
      for (var i = 0; i < n; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;
        var pi = platformIdx[i];
        var isActive = !filtering || activePlatforms.has(PLATFORMS[pi]);
        // pass 0 = dimmed (inactive), pass 1 = bright (active)
        if (filtering && ((pass === 0 && isActive) || (pass === 1 && !isActive))) continue;
        if (!filtering && pass === 1) continue;
        var sx = cx + px * scale, sy = cy + py * scale;
        if (i === hoveredIndex && useGlow) {
          var spr = sprites[pi].hover;
          ctx.drawImage(spr, sx - spr.width / (2 * dpr), sy - spr.height / (2 * dpr), spr.width / dpr, spr.height / dpr);
        } else if (useGlow) {
          var spr = sprites[pi].normal;
          ctx.drawImage(spr, sx - spr.width / (2 * dpr), sy - spr.height / (2 * dpr), spr.width / dpr, spr.height / dpr);
        } else {
          var dot = dotSprites[pi];
          ctx.drawImage(dot, sx - dot.width / (2 * dpr), sy - dot.height / (2 * dpr), dot.width / dpr, dot.height / dpr);
        }
      }
    }
    ctx.globalAlpha = 1;

    // --- search highlights ---
    if (searchMatches && searchMatches.size > 0) {
      // dim non-matching points by drawing a semi-transparent overlay
      ctx.globalAlpha = dark ? 0.6 : 0.5;
      ctx.fillStyle = dark ? '#050505' : '#f5f5f0';
      ctx.fillRect(0, 0, W, H);

      // redraw matched points brighter
      ctx.globalAlpha = 1;
      searchMatches.forEach(function(i) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) return;
        var sx = cx + px * scale, sy = cy + py * scale;
        var pi = platformIdx[i];
        if (useGlow) {
          var spr = sprites[pi].hover;
          ctx.drawImage(spr, sx - spr.width / (2 * dpr), sy - spr.height / (2 * dpr), spr.width / dpr, spr.height / dpr);
        } else {
          var dot = dotSprites[pi];
          ctx.drawImage(dot, sx - dot.width / (2 * dpr), sy - dot.height / (2 * dpr), dot.width / dpr, dot.height / dpr);
        }
      });

      // draw search centroid marker
      if (searchCenter) {
        var mx = cx + searchCenter.x * scale, my = cy + searchCenter.y * scale;
        var accent = dark ? 'rgba(250,200,80,' : 'rgba(200,120,0,';
        // outer ring — pulsing glow
        ctx.beginPath();
        ctx.arc(mx, my, 18, 0, Math.PI * 2);
        ctx.strokeStyle = accent + '0.25)';
        ctx.lineWidth = 3;
        ctx.stroke();
        // crosshair lines
        ctx.strokeStyle = accent + '0.8)';
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.moveTo(mx - 20, my); ctx.lineTo(mx - 8, my);
        ctx.moveTo(mx + 8, my); ctx.lineTo(mx + 20, my);
        ctx.moveTo(mx, my - 20); ctx.lineTo(mx, my - 8);
        ctx.moveTo(mx, my + 8); ctx.lineTo(mx, my + 20);
        ctx.stroke();
        // center dot
        ctx.beginPath();
        ctx.arc(mx, my, 3, 0, Math.PI * 2);
        ctx.fillStyle = accent + '0.9)';
        ctx.fill();
        // label with outline
        ctx.font = '12px monospace';
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.fillStyle = accent + '0.9)';
        drawLabel('"' + searchQuery + '"', mx + 24, my, dark);
      }
    }

    // --- labels with collision avoidance ---
    ctx.globalAlpha = 1;
    ctx.fillStyle = dark ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.65)';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    var small = W < 600;
    // placed label bounding boxes for collision detection
    var placed = []; // [{x, y, hw, hh}] — center + half-width/half-height
    var PAD = small ? 2 : 4; // padding between labels

    function canPlace(lx, ly, tw, th) {
      var hw = tw / 2 + PAD, hh = th / 2 + PAD;
      for (var k = 0; k < placed.length; k++) {
        var p = placed[k];
        if (Math.abs(lx - p.x) < hw + p.hw && Math.abs(ly - p.y) < hh + p.hh) return false;
      }
      placed.push({ x: lx, y: ly, hw: hw, hh: hh });
      return true;
    }

    // label margin: keep labels inside viewport with some padding
    var LABEL_MARGIN = small ? 8 : 12;

    // smooth label transitions:
    // coarse labels: full opacity zoom<1.7, fade out 1.7–2.3
    // fine labels: fade in 1.7–2.3, full opacity 2.3–4.5, fade out 4.5–5.5
    // titles: fade in 4.5–5.5, full opacity 5.5 until cards take over
    // cards: fade in over CARD_START..CARD_START+CARD_RANGE, then grow to CARD_FULL
    var coarseAlpha = fadeOut(zoom, 1.7, 0.6);
    var fineAlpha = fadeIn(zoom, 1.7, 0.6) * fadeOut(zoom, 4.5, 1.0);
    var titleAlpha = fadeIn(zoom, 4.5, 1.0) * fadeOut(zoom, CARD_START, CARD_RANGE);
    var cardAlpha = fadeIn(zoom, CARD_START, CARD_RANGE);

    // --- document cards: the close-up "HD" representation ---
    // drawn FIRST so cards win label collisions during the title crossfade.
    cardHitRects = null;
    if (cardAlpha > 0.01) {
      cardHitRects = [];
      // growth factor: cards upsize from the moment they're fully formed
      // (CARD_START+CARD_RANGE) until CARD_FULL
      var g = clamp01((zoom - (CARD_START + CARD_RANGE)) / (CARD_FULL - CARD_START - CARD_RANGE));
      function grow(a, b) { return a + (b - a) * g; }
      var cardW = small ? Math.min(W - 32, grow(160, 300)) : grow(190, 360);
      var padC = Math.round(grow(9, 16));
      var titleFont = Math.round(grow(11, 19));
      var metaFont = Math.round(grow(9, 13));
      var headFont = Math.round(grow(9, 12));
      var logoS = Math.round(grow(13, 20));
      var avatarS = Math.round(grow(20, 48));
      var lineH = Math.round(titleFont * 1.35);
      var maxTitleLines = g < 0.4 ? 2 : 3;
      // fewer cards while they're small (dense field), more as you close in
      var maxCards = small ? Math.round(5 + 3 * g) : Math.round(10 + 10 * g);
      var anchorGap = Math.round(grow(12, 22));
      var innerW = cardW - padC * 2;

      // nearest-to-viewport-center docs win the card slots
      var cands = [];
      var vcx = W / 2, vcy = H / 2;
      for (var i = 0; i < n; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;
        if (filtering && !activePlatforms.has(PLATFORMS[platformIdx[i]])) continue;
        var sx = cx + px * scale, sy = cy + py * scale;
        var ddx = sx - vcx, ddy = sy - vcy;
        cands.push({ i: i, sx: sx, sy: sy, d: ddx * ddx + ddy * ddy });
      }
      cands.sort(function(a, b) { return a.d - b.d; });

      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      var shownCards = 0;
      for (var c = 0; c < cands.length && shownCards < maxCards; c++) {
        var idx = cands[c].i;
        var p = data.points[idx];
        var sx = cands[c].sx, sy = cands[c].sy;
        var platform = PLATFORMS[platformIdx[idx]];
        var colors = frameColors[platform];
        var title = p.title || '(untitled)';

        ctx.font = titleFont + 'px monospace';
        var lines = wrapText(title, innerW, maxTitleLines);

        var pub = pubByBasePath ? pubByBasePath.get(p.basePath) : null;
        var showAvatar = pub && g > 0.1;
        var headH = showAvatar ? Math.max(logoS, avatarS) : logoS;
        var cardH = padC + headH + 7 + lines.length * lineH + 5 + metaFont + padC;

        var cardX = sx - cardW / 2;
        var cardY = sy - anchorGap - cardH;
        var below = false;
        if (cardY < 8) { cardY = sy + anchorGap; below = true; }
        // skip only when fully off-screen — a partially visible card stays
        // anchored to its dot, so there's no label/dot disconnect
        if (cardX > W || cardX + cardW < 0 || cardY > H || cardY + cardH < 0) continue;
        if (!canPlace(sx, cardY + cardH / 2, cardW, cardH)) continue;

        if (showAvatar) loadPubImage(pub);

        // connector from card edge to the dot it describes
        ctx.globalAlpha = cardAlpha * 0.5;
        ctx.strokeStyle = colors.mid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        if (below) { ctx.moveTo(sx, cardY); ctx.lineTo(sx, sy + 6); }
        else { ctx.moveTo(sx, cardY + cardH); ctx.lineTo(sx, sy - 6); }
        ctx.stroke();

        // card body
        ctx.globalAlpha = cardAlpha * 0.96;
        roundRectPath(cardX, cardY, cardW, cardH, 8);
        ctx.fillStyle = dark ? 'rgba(10,12,16,0.88)' : 'rgba(255,255,255,0.93)';
        ctx.fill();
        ctx.strokeStyle = idx === hoveredIndex ? colors.core : hexToRgba(colors.mid, 0.55);
        ctx.lineWidth = idx === hoveredIndex ? 2 : 1.5;
        ctx.stroke();

        // header: platform logo + name (left), publication avatar (right)
        var headCY = cardY + padC + headH / 2;
        var logo = platformLogos[platform];
        var hasLogo = logo && logo.complete && logo.naturalWidth > 0;
        var tx = cardX + padC;
        if (hasLogo) {
          ctx.drawImage(logo, tx, headCY - logoS / 2, logoS, logoS);
          tx += logoS + 5;
        }
        ctx.font = headFont + 'px monospace';
        ctx.fillStyle = colors.core;
        ctx.fillText(platform, tx, headCY);

        if (showAvatar) {
          var ax = cardX + cardW - padC - avatarS / 2;
          var img = pubImages[pub.basePath];
          if (img) {
            ctx.save();
            ctx.beginPath();
            ctx.arc(ax, headCY, avatarS / 2, 0, Math.PI * 2);
            ctx.clip();
            ctx.drawImage(img, ax - avatarS / 2, headCY - avatarS / 2, avatarS, avatarS);
            ctx.restore();
          } else {
            ctx.beginPath();
            ctx.arc(ax, headCY, avatarS / 2, 0, Math.PI * 2);
            ctx.fillStyle = colors.edge;
            ctx.fill();
            ctx.font = 'bold ' + Math.round(avatarS * 0.5) + 'px monospace';
            ctx.textAlign = 'center';
            ctx.fillStyle = colors.core;
            ctx.fillText(((pub.name || p.basePath || '?').charAt(0)).toUpperCase(), ax, headCY);
            ctx.textAlign = 'left';
          }
          ctx.beginPath();
          ctx.arc(ax, headCY, avatarS / 2, 0, Math.PI * 2);
          ctx.strokeStyle = hexToRgba(colors.mid, 0.6);
          ctx.lineWidth = 1;
          ctx.stroke();
        }

        // title lines
        ctx.font = titleFont + 'px monospace';
        ctx.fillStyle = dark ? 'rgba(255,255,255,0.92)' : 'rgba(0,0,0,0.85)';
        var ty = cardY + padC + headH + 7 + lineH / 2;
        for (var l = 0; l < lines.length; l++) {
          ctx.fillText(lines[l], cardX + padC, ty);
          ty += lineH;
        }

        // meta: where it lives
        var meta = p.basePath || (p.uri.split('/')[2] || '');
        if (meta) {
          ctx.font = metaFont + 'px monospace';
          ctx.fillStyle = dark ? 'rgba(255,255,255,0.45)' : 'rgba(0,0,0,0.45)';
          ctx.fillText(truncToChars(meta, innerW), cardX + padC, ty - lineH / 2 + 5 + metaFont / 2);
        }

        cardHitRects.push({ x: cardX, y: cardY, w: cardW, h: cardH, i: idx });
        shownCards++;
      }
      ctx.globalAlpha = 1;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
    }

    // CULLING RULE: labels stay anchored above their dot/cluster. If the
    // label would extend past the viewport edge, we CULL it rather than
    // shifting it inward — shifting created a label-at-edge / dot-elsewhere
    // disconnect where you couldn't tell which dot a label described.
    function fitsHoriz(lx, halfW) {
      return lx - halfW >= LABEL_MARGIN && lx + halfW <= W - LABEL_MARGIN;
    }

    if (coarseAlpha > 0.01) {
      ctx.font = (small ? '9px' : '12px') + ' monospace';
      ctx.globalAlpha = 0.85 * coarseAlpha;
      ctx.fillStyle = dark ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.65)';
      var fontSize = small ? 9 : 12;
      var sorted = data.clusters.coarse.slice().sort(function(a, b) { return b.count - a.count; });
      for (var c = 0; c < sorted.length; c++) {
        var cl = sorted[c];
        var sx = cx + cl.cx * scale, sy = cy + cl.cy * scale - Math.sqrt(cl.count) * 1.5;
        if (sy < LABEL_MARGIN || sy > H - 40) continue;
        var tw = ctx.measureText(cl.label).width;
        if (!fitsHoriz(sx, tw / 2)) continue;
        if (canPlace(sx, sy, tw, fontSize)) drawLabel(cl.label, sx, sy, dark);
      }
    }

    if (fineAlpha > 0.01) {
      ctx.font = (small ? '8px' : '11px') + ' monospace';
      ctx.globalAlpha = 0.75 * fineAlpha;
      ctx.fillStyle = dark ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.65)';
      var fontSize = small ? 8 : 11;
      var sorted = data.clusters.fine.slice().sort(function(a, b) { return b.count - a.count; });
      for (var c = 0; c < sorted.length; c++) {
        var cl = sorted[c];
        if (cl.cx < xMin || cl.cx > xMax || cl.cy < yMin || cl.cy > yMax) continue;
        var sx = cx + cl.cx * scale, sy = cy + cl.cy * scale - 14;
        if (sy < LABEL_MARGIN || sy > H - 40) continue;
        var tw = ctx.measureText(cl.label).width;
        if (!fitsHoriz(sx, tw / 2)) continue;
        if (canPlace(sx, sy, tw, fontSize)) drawLabel(cl.label, sx, sy, dark);
      }
    }

    if (titleAlpha > 0.01) {
      // Title cap stays at 20 mobile / 50 desktop regardless of zoom.
      // A previous attempt to lift these caps at high zoom flooded the
      // small viewport — the *screen size* dictates how many titles fit,
      // not how many dots are theoretically on screen. Font growth is
      // desktop-only and capped tight.
      var baseFont = small ? 9 : 11;
      var fontSize = baseFont + (small ? 0 : Math.min(2, Math.max(0, Math.floor((zoom - 25) / 10))));
      ctx.font = fontSize + 'px monospace';
      ctx.globalAlpha = 0.7 * titleAlpha;
      ctx.fillStyle = dark ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.65)';
      // Mobile screen is ~390px wide. With monospace text, 20 labels
      // overlap themselves to the point of being unreadable \u2014 drop the
      // mobile cap further. Desktop stays at 50.
      var maxLabels = small ? 10 : 50;
      var truncLen = small ? 22 : 45;
      var iconSize = small ? 12 : 14;
      var iconGap = 4;
      var shown = 0;

      for (var i = 0; i < n && shown < maxLabels; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;
        var title = data.points[i].title;
        if (!title) continue;
        var sx = cx + px * scale, sy = cy + py * scale - 10;
        if (sy < LABEL_MARGIN || sy > H - 40) continue;
        if (title.length > truncLen) title = title.substring(0, truncLen - 2) + '\u2026';
        var tw = ctx.measureText(title).width;

        // include the platform icon in the bounding box. If the logo isn't
        // ready yet, fall back to text-only positioning so the layout
        // doesn't jitter when icons load in.
        var platform = PLATFORMS[platformIdx[i]];
        var logo = platformLogos[platform];
        var hasLogo = logo && logo.complete && logo.naturalWidth > 0;
        var iconW = hasLogo ? (iconSize + iconGap) : 0;
        var contentW = iconW + tw;
        var halfW = contentW / 2;

        // CULL if the (icon + title) would extend past the viewport edge.
        // Shifting the label inward disconnects it from its dot and makes
        // it unclear which dot the label describes.
        if (!fitsHoriz(sx, halfW)) continue;
        if (canPlace(sx, sy, contentW, fontSize)) {
          if (hasLogo) {
            // draw the icon at the left, then shift the text center right so
            // the (icon + text) combo is centered on sx.
            ctx.drawImage(logo, sx - halfW, sy - iconSize / 2, iconSize, iconSize);
            drawLabel(title, sx - halfW + iconW + tw / 2, sy, dark);
          } else {
            drawLabel(title, sx, sy, dark);
          }
          shown++;
        }
      }
    }

    ctx.globalAlpha = 1;
  }

  // --- animation loop ---
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }

  function tickAnimation() {
    if (!animating) return;
    var t = Math.min(1, (Date.now() - animStart) / ANIM_DURATION);
    var e = easeOutCubic(t);
    view.zoom = animFrom.zoom + (animTo.zoom - animFrom.zoom) * e;
    view.panX = animFrom.panX + (animTo.panX - animFrom.panX) * e;
    view.panY = animFrom.panY + (animTo.panY - animFrom.panY) * e;
    view.dirty = true;
    if (t >= 1) animating = false;
  }

  function animateTo(targetX, targetY, targetZoom) {
    animFrom = { zoom: view.zoom, panX: view.panX, panY: view.panY };
    animTo = { zoom: targetZoom, panX: -targetX, panY: -targetY };
    animStart = Date.now();
    animating = true;
    scheduleFrame();
  }

  function loop() {
    frameRequested = false;
    tickAnimation();
    render();
    // keep looping only while animating
    if (animating) {
      scheduleFrame();
    }
  }

  // --- hover state ---
  var hoveredIndex = -1;
  var hoveredPub = -1; // index into pubData
  var mouseX = 0, mouseY = 0;

  function findNearestPub(sx, sy) {
    if (!pubData || pubData.length === 0) return -1;
    cacheTransform();
    var z = view.zoom;
    for (var i = 0; i < pubData.length; i++) {
      var pub = pubData[i];
      var pr = Math.min(28, Math.sqrt(pub.count) * z * 0.35);
      if (pr < 4) continue;
      var psx = cx + pub.cx * scale, psy = cy + pub.cy * scale;
      var dx = sx - psx, dy = sy - psy;
      if (dx * dx + dy * dy <= pr * pr) return i;
    }
    return -1;
  }

  function pubUrl(pub) {
    if (pub.basePath) return 'https://' + pub.basePath;
    return null;
  }

  function showPubTooltip(pubIdx, sx, sy) {
    var pub = pubData[pubIdx];
    tooltipTitle.textContent = pub.name || pub.basePath;
    tooltipMeta.textContent = pub.count + ' documents';
    tooltipPlatform.textContent = pub.platform || 'other';
    var c = frameColors[pub.platform] || frameColors.other;
    tooltipPlatform.style.background = c.edge;
    tooltipPlatform.style.color = c.core;
    tooltip.style.display = 'block';
    var tw = tooltip.offsetWidth, th = tooltip.offsetHeight;
    if (isMobile) {
      var tx = Math.max(8, Math.min(W - tw - 8, (W - tw) / 2));
      tooltip.style.left = tx + 'px';
      tooltip.style.top = '48px';
    } else {
      var tx = sx + 16, ty = sy - th - 8;
      if (tx + tw > W - 10) tx = sx - tw - 16;
      if (ty < 10) ty = sy + 16;
      tooltip.style.left = tx + 'px';
      tooltip.style.top = ty + 'px';
    }
    canvas.style.cursor = 'pointer';
  }

  // --- mobile detection ---
  var isMobile = 'ontouchstart' in window || navigator.maxTouchPoints > 0;
  var HIT_RADIUS = isMobile ? 40 : 20;

  // --- interaction state ---
  var dragging = false;
  var dragStartX, dragStartY, dragStartPanX, dragStartPanY;
  var pinchStartDist = 0, pinchStartZoom = 1;
  var pinchMidX = 0, pinchMidY = 0, pinchStartPanX = 0, pinchStartPanY = 0;

  canvas.addEventListener('wheel', function(e) {
    e.preventDefault();
    // scale zoom proportionally to deltaY — gentle for trackpad, snappy for mouse wheel
    // deltaMode 1 = lines (mouse wheel): multiply by 40 to approximate pixels
    var dy = e.deltaMode === 1 ? e.deltaY * 40 : e.deltaY;
    var factor = Math.pow(0.995, dy); // balanced: smooth trackpad, snappy mouse wheel
    var newZoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * factor));
    cacheTransform();
    var d = screenToData(e.clientX, e.clientY);
    view.zoom = newZoom;
    cacheTransform();
    var d2 = screenToData(e.clientX, e.clientY);
    view.panX += d2[0] - d[0];
    view.panY += d2[1] - d[1];
    markDirty();
  }, { passive: false });

  canvas.addEventListener('mousedown', function(e) {
    if (e.button !== 0) return;
    dragging = true;
    dragStartX = e.clientX; dragStartY = e.clientY;
    dragStartPanX = view.panX; dragStartPanY = view.panY;
  });

  window.addEventListener('mousemove', function(e) {
    mouseX = e.clientX; mouseY = e.clientY;
    if (dragging) {
      cacheTransform();
      view.panX = dragStartPanX + (e.clientX - dragStartX) / scale;
      view.panY = dragStartPanY + (e.clientY - dragStartY) / scale;
      markDirty();
      hideTooltip();
      return;
    }
    cacheTransform();
    // document cards are topmost — they show everything the tooltip would,
    // so hovering one just highlights it and arms the click
    var cardIdx = findCardAt(mouseX, mouseY);
    if (cardIdx >= 0) {
      if (hoveredIndex !== cardIdx || hoveredPub !== -1) {
        hoveredPub = -1;
        hoveredIndex = cardIdx;
        tooltip.style.display = 'none';
        markDirty();
      }
      canvas.style.cursor = 'pointer';
      return;
    }
    // check publications next (rendered on top of points)
    var pi = findNearestPub(mouseX, mouseY);
    if (pi >= 0) {
      if (hoveredPub !== pi) {
        hoveredPub = pi;
        hoveredIndex = -1;
        markDirty();
        showPubTooltip(pi, mouseX, mouseY);
      }
      return;
    }
    hoveredPub = -1;
    var idx = findNearest(mouseX, mouseY, HIT_RADIUS);
    if (idx !== hoveredIndex) {
      hoveredIndex = idx;
      markDirty();
      if (idx >= 0) showTooltip(idx, mouseX, mouseY);
      else hideTooltip();
    }
  });

  window.addEventListener('mouseup', function(e) {
    if (dragging) {
      if (Math.abs(e.clientX - dragStartX) < 4 && Math.abs(e.clientY - dragStartY) < 4) {
        // check publication click first
        if (hoveredPub >= 0) {
          var url = pubUrl(pubData[hoveredPub]);
          if (url) window.open(url, '_blank');
        } else if (hoveredIndex >= 0) {
          var p = data.points[hoveredIndex];
          var url = atUriToUrl(p.uri, p.basePath, p.platform, p.path);
          if (url) window.open(url, '_blank');
        }
      }
      dragging = false;
    }
  });

  // --- touch ---
  var touches = {};
  var touchMoved = false;
  var selectedIndex = -1; // for tap-to-select, tap-again-to-open

  canvas.addEventListener('touchstart', function(e) {
    e.preventDefault();
    for (var i = 0; i < e.changedTouches.length; i++) {
      var t = e.changedTouches[i];
      touches[t.identifier] = { x: t.clientX, y: t.clientY };
    }
    touchMoved = false;
    var ids = Object.keys(touches);
    if (ids.length === 1) {
      dragging = true;
      dragStartX = touches[ids[0]].x; dragStartY = touches[ids[0]].y;
      dragStartPanX = view.panX; dragStartPanY = view.panY;
    } else if (ids.length === 2) {
      dragging = false;
      var a = touches[ids[0]], b = touches[ids[1]];
      pinchStartDist = Math.hypot(a.x - b.x, a.y - b.y);
      pinchStartZoom = view.zoom;
      pinchMidX = (a.x + b.x) / 2;
      pinchMidY = (a.y + b.y) / 2;
      pinchStartPanX = view.panX;
      pinchStartPanY = view.panY;
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', function(e) {
    e.preventDefault();
    for (var i = 0; i < e.changedTouches.length; i++) {
      var t = e.changedTouches[i];
      touches[t.identifier] = { x: t.clientX, y: t.clientY };
    }
    touchMoved = true;
    var ids = Object.keys(touches);
    if (ids.length === 1 && dragging) {
      cacheTransform();
      view.panX = dragStartPanX + (touches[ids[0]].x - dragStartX) / scale;
      view.panY = dragStartPanY + (touches[ids[0]].y - dragStartY) / scale;
      markDirty();
      hideTooltip();
      selectedIndex = -1;
    } else if (ids.length === 2) {
      var a = touches[ids[0]], b = touches[ids[1]];
      var dist = Math.hypot(a.x - b.x, a.y - b.y);
      var newZoom = Math.max(view.minZoom, Math.min(view.maxZoom, pinchStartZoom * (dist / pinchStartDist)));
      // zoom toward pinch midpoint
      var midDataOld = screenToData(pinchMidX, pinchMidY);
      view.zoom = newZoom;
      cacheTransform();
      var midDataNew = screenToData(pinchMidX, pinchMidY);
      view.panX += midDataNew[0] - midDataOld[0];
      view.panY += midDataNew[1] - midDataOld[1];
      markDirty();
    }
  }, { passive: false });

  canvas.addEventListener('touchend', function(e) {
    var endedTouches = [];
    for (var i = 0; i < e.changedTouches.length; i++) {
      endedTouches.push(e.changedTouches[i]);
      delete touches[e.changedTouches[i].identifier];
    }
    var remaining = Object.keys(touches).length;
    if (remaining === 0) {
      dragging = false;
      // tap detection — didn't drag significantly
      if (!touchMoved || (endedTouches.length === 1 &&
          Math.abs(endedTouches[0].clientX - dragStartX) < 10 &&
          Math.abs(endedTouches[0].clientY - dragStartY) < 10)) {
        var tx = endedTouches[0].clientX, ty = endedTouches[0].clientY;
        cacheTransform();
        // document cards are topmost: first tap selects (highlight border),
        // second tap opens — same pattern as dots, minus the redundant tooltip
        var cardIdx = findCardAt(tx, ty);
        if (cardIdx >= 0) {
          if (cardIdx === selectedIndex) {
            var cp = data.points[cardIdx];
            var cu = atUriToUrl(cp.uri, cp.basePath, cp.platform, cp.path);
            if (cu) window.open(cu, '_blank');
            selectedIndex = -1;
            hideTooltip();
          } else {
            selectedIndex = cardIdx;
            hoveredIndex = cardIdx;
            tooltip.style.display = 'none';
            markDirty();
          }
          return;
        }
        // check publications next
        var pi = findNearestPub(tx, ty);
        if (pi >= 0) {
          var url = pubUrl(pubData[pi]);
          if (url) window.open(url, '_blank');
          selectedIndex = -1;
          hideTooltip();
        } else {
          var idx = findNearest(tx, ty, HIT_RADIUS);
          if (idx >= 0) {
            if (idx === selectedIndex) {
              var p = data.points[idx];
              var url = atUriToUrl(p.uri, p.basePath, p.platform, p.path);
              if (url) window.open(url, '_blank');
              selectedIndex = -1;
              hideTooltip();
            } else {
              selectedIndex = idx;
              hoveredIndex = idx;
              showTooltip(idx, tx, ty);
              markDirty();
            }
          } else {
            selectedIndex = -1;
            hideTooltip();
            markDirty();
          }
        }
      }
    }
  });

  // --- tooltip ---
  var tooltip = document.getElementById('tooltip');
  var tooltipTitle = document.getElementById('tooltip-title');
  var tooltipMeta = document.getElementById('tooltip-meta');
  var tooltipPlatform = document.getElementById('tooltip-platform');

  function showTooltip(idx, sx, sy) {
    var p = data.points[idx];
    tooltipTitle.textContent = p.title || '(untitled)';
    tooltipMeta.textContent = p.basePath || p.uri;
    tooltipPlatform.textContent = p.platform;
    var c = frameColors[p.platform] || frameColors.other;
    tooltipPlatform.style.background = c.edge;
    tooltipPlatform.style.color = c.core;
    tooltip.style.display = 'block';
    var tw = tooltip.offsetWidth, th = tooltip.offsetHeight;
    if (isMobile) {
      // on mobile, anchor tooltip at top center of screen
      var tx = Math.max(8, Math.min(W - tw - 8, (W - tw) / 2));
      tooltip.style.left = tx + 'px';
      tooltip.style.top = '48px';
    } else {
      var tx = sx + 16, ty = sy - th - 8;
      if (tx + tw > W - 10) tx = sx - tw - 16;
      if (ty < 10) ty = sy + 16;
      tooltip.style.left = tx + 'px';
      tooltip.style.top = ty + 'px';
    }
    canvas.style.cursor = 'pointer';
  }

  function hideTooltip() {
    tooltip.style.display = 'none';
    hoveredIndex = -1;
    hoveredPub = -1;
    canvas.style.cursor = dragging ? 'grabbing' : 'grab';
  }

  function atUriToUrl(uri, basePath, platform, path) {
    var m = uri.match(/^at:\/\/(did:[^/]+)\/([^/]+)\/(.+)$/);
    if (!m) return null;
    var did = m[1], collection = m[2], rkey = m[3];
    if (platform === 'whitewind' || collection.startsWith('com.whtwnd.')) return 'https://whtwnd.com/' + did + '/' + rkey;
    // skip non-document-serving hosts (blento is a card portal, not a document platform)
    var usableBase = basePath && !basePath.startsWith('blento.app');
    // explicit path wins — the rkey form below is a leaflet.pub convention and must
    // not override an author-set path (site.standard.document records embedding
    // pub.leaflet.content get tagged platform=leaflet but are served by their path)
    if (usableBase && path) {
      var sep = path.charAt(0) === '/' ? '' : '/';
      return 'https://' + basePath + sep + path;
    }
    // leaflet uses rkey directly
    if (platform === 'leaflet' && usableBase) return 'https://' + basePath + '/' + rkey;
    // leaflet without basePath
    if (platform === 'leaflet') return 'https://leaflet.pub/p/' + did + '/' + rkey;
    if (usableBase) return 'https://' + basePath + '/' + rkey;
    // universal fallback — AT Protocol record viewer
    return 'https://pdsls.dev/at/' + did + '/' + collection + '/' + rkey;
  }

  // --- platform filter state ---
  var activePlatforms = null; // null = all visible, Set = only these

  function renderLegend() {
    var el = document.getElementById('legend');
    if (!frameColors) cacheFrameColors();
    var html = '';
    for (var i = 0; i < PLATFORMS.length; i++) {
      var p = PLATFORMS[i];
      var dimmed = activePlatforms && !activePlatforms.has(p) ? ' dimmed' : '';
      html += '<div class="legend-item' + dimmed + '" data-platform="' + p + '"><span class="legend-dot" style="background:' + frameColors[p].mid + '"></span>' + p + '</div>';
    }
    el.innerHTML = html;
    // attach click handlers
    var items = el.querySelectorAll('.legend-item');
    for (var i = 0; i < items.length; i++) {
      items[i].addEventListener('click', onLegendClick);
    }
  }

  function onLegendClick(e) {
    var item = e.currentTarget;
    var platform = item.getAttribute('data-platform');
    if (!activePlatforms) {
      // first click: select only this platform
      activePlatforms = new Set([platform]);
    } else if (activePlatforms.has(platform)) {
      activePlatforms.delete(platform);
      // if nothing selected, show all
      if (activePlatforms.size === 0) activePlatforms = null;
    } else {
      activePlatforms.add(platform);
      // if all selected, reset to null
      if (activePlatforms.size === PLATFORMS.length) activePlatforms = null;
    }
    renderLegend();
    markDirty();
  }

  function loadData() {
    // start logo prefetch in parallel — they're small (<60KB total) and we
    // want them ready by the time the user zooms in far enough for titles.
    loadPlatformLogos();
    fetch('atlas.json')
      .then(function(r) {
        if (!r.ok) throw new Error('failed to load atlas.json: ' + r.status);
        return r.json();
      })
      .then(function(d) {
        data = d;
        var n = d.points.length;
        pointsX = new Float32Array(n);
        pointsY = new Float32Array(n);
        platformIdx = new Uint8Array(n);
        var platMap = {};
        for (var p = 0; p < PLATFORMS.length; p++) platMap[PLATFORMS[p]] = p;
        var otherIdx = platMap.other;
        for (var i = 0; i < n; i++) {
          pointsX[i] = d.points[i].x;
          pointsY[i] = d.points[i].y;
          platformIdx[i] = platMap[d.points[i].platform] !== undefined ? platMap[d.points[i].platform] : otherIdx;
        }
        // build URI → index map for search matching
        uriToIndex = new Map();
        for (var i = 0; i < n; i++) {
          uriToIndex.set(d.points[i].uri, i);
        }
        // build cluster metadata: fine cluster array, dominant platform, spatial radius
        clusterFineArr = new Uint8Array(n);
        var coarsePlatCounts = {};
        var finePlatCounts = {};
        for (var i = 0; i < n; i++) {
          var cc = d.points[i].clusterCoarse;
          var cf = d.points[i].clusterFine;
          clusterFineArr[i] = cf;
          if (!coarsePlatCounts[cc]) coarsePlatCounts[cc] = new Uint16Array(PLATFORMS.length);
          if (!finePlatCounts[cf]) finePlatCounts[cf] = new Uint16Array(PLATFORMS.length);
          coarsePlatCounts[cc][platformIdx[i]]++;
          finePlatCounts[cf][platformIdx[i]]++;
        }
        function dominantPlatform(counts) {
          if (!counts) return 'other';
          var best = 0, bestP = 0;
          for (var p = 0; p < PLATFORMS.length; p++) {
            if (counts[p] > best) { best = counts[p]; bestP = p; }
          }
          return PLATFORMS[bestP];
        }
        var coarseById = {};
        for (var c = 0; c < d.clusters.coarse.length; c++) {
          var cl = d.clusters.coarse[c];
          cl.dominantPlatform = dominantPlatform(coarsePlatCounts[cl.id]);
          cl._distSum = 0; cl._distN = 0;
          coarseById[cl.id] = cl;
        }
        var fineById = {};
        for (var c = 0; c < d.clusters.fine.length; c++) {
          var cl = d.clusters.fine[c];
          cl.dominantPlatform = dominantPlatform(finePlatCounts[cl.id]);
          cl._distSum = 0; cl._distN = 0;
          fineById[cl.id] = cl;
        }
        for (var i = 0; i < n; i++) {
          var ccl = coarseById[d.points[i].clusterCoarse];
          if (ccl) {
            var dx = pointsX[i] - ccl.cx, dy = pointsY[i] - ccl.cy;
            ccl._distSum += Math.sqrt(dx * dx + dy * dy);
            ccl._distN++;
          }
          var fcl = fineById[d.points[i].clusterFine];
          if (fcl) {
            var dx = pointsX[i] - fcl.cx, dy = pointsY[i] - fcl.cy;
            fcl._distSum += Math.sqrt(dx * dx + dy * dy);
            fcl._distN++;
          }
        }
        for (var c = 0; c < d.clusters.coarse.length; c++) {
          var cl = d.clusters.coarse[c];
          cl.radius = cl._distN > 0 ? (cl._distSum / cl._distN) * 2 : 0.05;
        }
        for (var c = 0; c < d.clusters.fine.length; c++) {
          var cl = d.clusters.fine[c];
          cl.radius = cl._distN > 0 ? (cl._distSum / cl._distN) * 2 : 0.02;
        }
        // load publication data
        pubData = d.publications || [];
        pubByBasePath = new Map();
        for (var pi = 0; pi < pubData.length; pi++) {
          if (pubData[pi].basePath) pubByBasePath.set(pubData[pi].basePath, pubData[pi]);
        }
        buildSpatialIndex();
        renderLegend();
        var statsText = n.toLocaleString() + ' documents \u00B7 ' +
          d.clusters.coarse.length + ' regions \u00B7 ' +
          d.clusters.fine.length + ' clusters';
        if (pubData.length > 0) statsText += ' \u00B7 ' + pubData.length + ' publications';
        document.getElementById('stats').textContent = statsText;
        document.getElementById('loading').classList.add('hidden');
        markDirty();
        // jump to specific document by URI (from "view on atlas" links)
        if (pendingUri) {
          var idx = uriToIndex.get(pendingUri);
          if (idx !== undefined) {
            searchMatches = new Set([idx]);
            searchCenter = { x: pointsX[idx], y: pointsY[idx] };
            searchQuery = d.points[idx].title || '';
            setSearchStatus('1 document');
            animateTo(searchCenter.x, searchCenter.y, pendingZoom || 12);
            // show tooltip after animation — unless we land at card zoom,
            // where the document card already shows everything
            setTimeout(function() {
              cacheTransform();
              var sx = cx + pointsX[idx] * scale;
              var sy = cy + pointsY[idx] * scale;
              hoveredIndex = idx;
              selectedIndex = idx;
              if (view.zoom < CARD_START) showTooltip(idx, sx, sy);
              else markDirty();
            }, ANIM_DURATION + 50);
          }
          pendingUri = null;
        }
        // jump to publication centroid (from "view publication on atlas" links)
        else if (pendingPub) {
          var pub = pubByBasePath && pubByBasePath.get(pendingPub);
          if (pub) {
            setSearchStatus(pub.name || pub.basePath);
            animateTo(pub.cx, pub.cy, 7);
          } else {
            setSearchStatus('publication not on atlas');
          }
          pendingPub = null;
        }
        // apply prefetched search results (fired in parallel with atlas.json)
        else if (pendingSearchResults) {
          pendingSearchResults.then(function(resp) {
            pendingSearchResults = null;
            if (resp) applySearchResults(resp, searchInput.value);
          });
        }
      })
      .catch(function(err) {
        document.getElementById('loading').querySelector('.spinner').textContent = 'error: ' + err.message;
        console.error(err);
      });
  }

  // --- search ---
  var API_URL = 'https://leaflet-search-backend.fly.dev';
  var searchInput = document.getElementById('search-input');
  var searchForm = document.getElementById('search-form');
  var searchStatusEl = null;
  var pendingSearchResults = null; // promise for prefetched search results
  var pendingUri = null; // URI to jump to after data loads (from "view on atlas" links)
  var pendingPub = null; // basePath to jump to (from "view publication on atlas" links)
  var pendingZoom = null; // ?z= zoom override for uri deep-links

  window.addEventListener('resize', resizeCanvas);
  resizeCanvas();
  // jump to specific document by URI, publication by basePath, or prefetch search results
  var urlParams = new URLSearchParams(window.location.search);
  var urlUri = urlParams.get('uri');
  var urlPub = urlParams.get('pub');
  var urlQ = urlParams.get('q');
  // optional zoom override for ?uri= deep-links (also handy for debugging)
  var urlZ = parseFloat(urlParams.get('z'));
  if (urlZ > 0) pendingZoom = Math.max(view.minZoom, Math.min(view.maxZoom, urlZ));
  if (urlUri) {
    pendingUri = urlUri;
  } else if (urlPub) {
    pendingPub = urlPub;
  } else if (urlQ) {
    searchInput.value = urlQ;
    pendingSearchResults = fetch(API_URL + buildSearchUrl(urlQ))
      .then(function(r) { return r.ok ? r.json() : null; })
      .catch(function() { return null; });
  }
  loadData();
  scheduleFrame();

  function setSearchStatus(msg) {
    if (!searchStatusEl) {
      searchStatusEl = document.createElement('span');
      searchStatusEl.className = 'search-status';
      searchForm.appendChild(searchStatusEl);
    }
    searchStatusEl.textContent = msg;
  }

  function clearSearch() {
    searchMatches = null;
    searchCenter = null;
    searchQuery = '';
    setSearchStatus('');
    var url = new URL(window.location);
    if (url.searchParams.has('q')) {
      url.searchParams.delete('q');
      history.replaceState(null, '', url);
    }
    markDirty();
  }

  function applySearchResults(resp, query) {
    searchQuery = query;
    var results = (resp && resp.results) || [];
    if (results.length === 0) {
      setSearchStatus('no results');
      searchMatches = null;
      searchCenter = null;
      markDirty();
      return;
    }

    // match result URIs to atlas points
    var matches = new Set();
    var weightedX = 0, weightedY = 0, totalWeight = 0;
    for (var i = 0; i < results.length; i++) {
      var uri = results[i].uri;
      if (uriToIndex && uriToIndex.has(uri)) {
        var idx = uriToIndex.get(uri);
        matches.add(idx);
        var w = results.length - i;
        weightedX += pointsX[idx] * w;
        weightedY += pointsY[idx] * w;
        totalWeight += w;
      }
    }

    if (matches.size === 0) {
      setSearchStatus(results.length + ' results, 0 on map');
      searchMatches = null;
      searchCenter = null;
      markDirty();
      return;
    }

    searchMatches = matches;
    searchCenter = { x: weightedX / totalWeight, y: weightedY / totalWeight };
    setSearchStatus(matches.size + ' of ' + results.length + ' on map');

    var maxDist = 0;
    matches.forEach(function(idx) {
      var dx = pointsX[idx] - searchCenter.x;
      var dy = pointsY[idx] - searchCenter.y;
      var d = Math.sqrt(dx * dx + dy * dy);
      if (d > maxDist) maxDist = d;
    });

    var targetZoom = maxDist > 0 ? Math.min(view.maxZoom, 0.3 / maxDist) : 6;
    targetZoom = Math.max(4, Math.min(15, targetZoom));
    animateTo(searchCenter.x, searchCenter.y, targetZoom);
  }

  // mirrors index.html's `@handle.tld` extraction so the syntax is
  // consistent across pages. unquoted `@handle.tld` or `@did:plc:...`
  // becomes an `author=` filter; the rest is the q text.
  function parseSearchQuery(raw) {
    var unquoted = raw.replace(/"[^"]*"/g, '');
    var didMatch = unquoted.match(/(?:^|\s)@(did:[a-z]+:[A-Za-z0-9._:-]+)/);
    var handleMatch = !didMatch && unquoted.match(/(?:^|\s)@([\w.-]+\.\w+)/);
    var text = raw.trim();
    var author = null;
    if (didMatch) {
      author = didMatch[1];
      text = raw.replace(new RegExp('\\s*@' + author.replace(/[.:]/g, '\\$&') + '\\s*'), ' ').trim();
    } else if (handleMatch) {
      author = handleMatch[1];
      text = raw.replace(new RegExp('\\s*@' + author.replace(/\./g, '\\.') + '\\s*'), ' ').trim();
    }
    return { text: text, author: author };
  }

  // when filter-only (author set, no text), use keyword mode — semantic
  // needs a query to embed and would return nothing.
  function buildSearchUrl(raw) {
    var parsed = parseSearchQuery(raw);
    var mode = (parsed.text.length === 0 && parsed.author) ? 'keyword' : 'semantic';
    var url = '/search?mode=' + mode + '&limit=20&format=v2&q=' + encodeURIComponent(parsed.text);
    if (parsed.author) url += '&author=' + encodeURIComponent(parsed.author);
    return url;
  }

  function doSearch(query, skipPush) {
    if (!query || !data || !uriToIndex) return;
    setSearchStatus('searching...');
    if (!skipPush) {
      var url = new URL(window.location);
      url.searchParams.set('q', query);
      history.replaceState(null, '', url);
    }

    fetch(API_URL + buildSearchUrl(query))
      .then(function(r) {
        if (!r.ok) throw new Error('search failed: ' + r.status);
        return r.json();
      })
      .then(function(resp) { applySearchResults(resp, query); })
      .catch(function(err) {
        setSearchStatus('error');
        console.error(err);
      });
  }

  // register typeahead FIRST so its keydown handler intercepts Enter/Escape
  // before the form submit / clear-search handlers below see them.
  if (window.LeafletUI) {
    window.LeafletUI.setupTypeahead(searchInput, {
      onPick: function() {
        if (searchForm.requestSubmit) searchForm.requestSubmit();
        else searchForm.dispatchEvent(new Event('submit', { cancelable: true }));
      },
    });
  }

  searchForm.addEventListener('submit', function(e) {
    e.preventDefault();
    var q = searchInput.value.trim();
    if (q) doSearch(q);
    else clearSearch();
  });

  // bare Escape (when typeahead is closed) clears the search. typeahead
  // intercepts Escape via stopImmediatePropagation when its dropdown is
  // open, so this only fires in the closed state.
  searchInput.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
      searchInput.value = '';
      searchInput.blur();
      clearSearch();
    }
  });

  // cmd+k / ctrl+k to focus search
  window.addEventListener('keydown', function(e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      searchInput.focus();
      searchInput.select();
    }
  });

  window.atlas = {
    setDirty: function() {
      sprites = null;
      dotSprites = null;
      haloSprites = null;
      renderLegend();
      markDirty();
    }
  };
})();
