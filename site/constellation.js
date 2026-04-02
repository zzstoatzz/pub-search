(function() {
  'use strict';

  // --- platform colors: [core, mid, edge] triplets ---
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

  function getColors() {
    return document.documentElement.getAttribute('data-theme') === 'light'
      ? PLATFORM_COLORS_LIGHT : PLATFORM_COLORS;
  }

  function isDark() {
    return document.documentElement.getAttribute('data-theme') !== 'light';
  }

  // --- view state ---
  var view = { zoom: 1, panX: 0, panY: 0, minZoom: 0.5, maxZoom: 15, dirty: true };

  // --- data ---
  var data = null;
  var pointsX = null;   // Float32Array
  var pointsY = null;
  var platformIdx = null; // Uint8Array — index into PLATFORMS
  var gridIndex = null;

  // --- canvas ---
  var canvas = document.getElementById('canvas');
  var ctx = canvas.getContext('2d');
  var dpr = window.devicePixelRatio || 1;
  var W, H;

  // --- sprite cache: pre-rendered point images per platform ---
  // sprites[platformIndex] = { normal: OffscreenCanvas, hover: OffscreenCanvas }
  var sprites = null;
  var spriteSize = 0;     // current sprite pixel size
  var spriteTheme = null; // 'dark' or 'light' — rebuild on change

  function buildSprites(radius) {
    var size = Math.ceil(radius * 6 * dpr) + 2;
    if (size < 4) size = 4;
    var half = size / 2;
    var colors = getColors();
    var theme = isDark() ? 'dark' : 'light';

    // skip rebuild if nothing changed
    if (sprites && spriteSize === size && spriteTheme === theme) return;
    spriteSize = size;
    spriteTheme = theme;

    sprites = [];
    for (var p = 0; p < PLATFORMS.length; p++) {
      var c = colors[PLATFORMS[p]];
      sprites.push({
        normal: makeSprite(size, half, radius * dpr, c, 0.7),
        hover:  makeSprite(size * 2, size, radius * dpr * 2, c, 1.0),
      });
    }
  }

  function makeSprite(size, half, r, colors, alpha) {
    var cv = document.createElement('canvas');
    cv.width = size; cv.height = size;
    var c = cv.getContext('2d');

    // radial gradient — drawn once, stamped many times
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

    // bright core
    c.globalAlpha = alpha * 0.9;
    c.fillStyle = colors.core;
    c.beginPath();
    c.arc(half, half, r * 0.5, 0, Math.PI * 2);
    c.fill();

    return cv;
  }

  // --- tiny dot sprite for zoomed-out view (1-2px per point) ---
  var dotSprites = null;
  var dotTheme = null;

  function buildDotSprites() {
    var theme = isDark() ? 'dark' : 'light';
    if (dotSprites && dotTheme === theme) return;
    dotTheme = theme;
    var colors = getColors();
    dotSprites = [];
    var s = Math.max(4, Math.ceil(3 * dpr));
    for (var p = 0; p < PLATFORMS.length; p++) {
      var cv = document.createElement('canvas');
      cv.width = s; cv.height = s;
      var c = cv.getContext('2d');
      c.fillStyle = colors[PLATFORMS[p]].mid;
      c.globalAlpha = 0.7;
      c.beginPath();
      c.arc(s / 2, s / 2, s / 2, 0, Math.PI * 2);
      c.fill();
      dotSprites.push(cv);
    }
  }

  // --- resize ---
  function resizeCanvas() {
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    sprites = null; // force rebuild
    dotSprites = null;
    view.dirty = true;
  }

  // --- coordinate transforms ---
  function dataToScreenX(dx) {
    return W / 2 + (dx + view.panX) * Math.min(W, H) * 0.42 * view.zoom;
  }
  function dataToScreenY(dy) {
    return H / 2 + (dy + view.panY) * Math.min(W, H) * 0.42 * view.zoom;
  }

  function screenToData(sx, sy) {
    var scale = Math.min(W, H) * 0.42 * view.zoom;
    return [(sx - W / 2) / scale - view.panX, (sy - H / 2) / scale - view.panY];
  }

  // --- spatial index (grid-based) ---
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
    var searchRadius = maxDist / (Math.min(W, H) * 0.42 * view.zoom);
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

  // --- rendering ---
  function render() {
    if (!data || !view.dirty) return;
    view.dirty = false;

    var dark = isDark();
    var zoom = view.zoom;
    var n = data.points.length;

    // background
    ctx.globalAlpha = 1;
    ctx.fillStyle = dark ? '#050505' : '#f5f5f0';
    ctx.fillRect(0, 0, W, H);

    // visible bounds in data space (with padding)
    var tl = screenToData(0, 0);
    var br = screenToData(W, H);
    var pad = 0.05;
    var xMin = tl[0] - pad, xMax = br[0] + pad;
    var yMin = tl[1] - pad, yMax = br[1] + pad;

    // --- cluster glows (zoomed out, few items — OK to use gradients) ---
    if (zoom < 4) {
      var clusters = zoom < 2 ? data.clusters.coarse : data.clusters.fine;
      ctx.globalAlpha = zoom < 2 ? 0.6 : 0.3;
      for (var c = 0; c < clusters.length; c++) {
        var cl = clusters[c];
        var sx = dataToScreenX(cl.cx), sy = dataToScreenY(cl.cy);
        if (sx < -100 || sx > W + 100 || sy < -100 || sy > H + 100) continue;
        var r = Math.sqrt(cl.count) * 2;
        var grad = ctx.createRadialGradient(sx, sy, 0, sx, sy, r);
        grad.addColorStop(0, dark ? 'rgba(255,255,255,0.03)' : 'rgba(0,0,0,0.02)');
        grad.addColorStop(1, 'transparent');
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.arc(sx, sy, r, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    // --- connection lines (zoomed in, spatial-index accelerated) ---
    if (zoom >= 3 && gridIndex) {
      var connRadius = 0.025; // data-space distance for connections
      var cs = gridIndex.cellSize;
      var lineColor = dark ? 'rgba(255,255,255,' : 'rgba(0,0,0,';
      ctx.lineWidth = 0.5;
      var drawn = {}; // avoid duplicate edges
      var maxLines = 2000;
      var lineCount = 0;

      for (var i = 0; i < n && lineCount < maxLines; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;

        var gxMin2 = Math.floor((px - connRadius) / cs);
        var gxMax2 = Math.floor((px + connRadius) / cs);
        var gyMin2 = Math.floor((py - connRadius) / cs);
        var gyMax2 = Math.floor((py + connRadius) / cs);

        var sx1 = dataToScreenX(px), sy1 = dataToScreenY(py);

        for (var gx = gxMin2; gx <= gxMax2 && lineCount < maxLines; gx++) {
          for (var gy = gyMin2; gy <= gyMax2 && lineCount < maxLines; gy++) {
            var cell = gridIndex.cells[gx + ',' + gy];
            if (!cell) continue;
            for (var k = 0; k < cell.length && lineCount < maxLines; k++) {
              var j = cell[k];
              if (j <= i) continue; // avoid duplicates
              var dx = pointsX[j] - px, dy = pointsY[j] - py;
              var dist2 = dx * dx + dy * dy;
              if (dist2 > connRadius * connRadius || dist2 < 0.0001) continue;
              var dist = Math.sqrt(dist2);
              var opacity = (1 - dist / connRadius) * 0.12;
              ctx.beginPath();
              ctx.moveTo(sx1, sy1);
              ctx.lineTo(dataToScreenX(pointsX[j]), dataToScreenY(pointsY[j]));
              ctx.strokeStyle = lineColor + opacity + ')';
              ctx.stroke();
              lineCount++;
            }
          }
        }
      }
    }

    // --- points: sprite-stamped ---
    ctx.globalAlpha = 1;

    var useGlow = zoom >= 2;
    if (useGlow) {
      var pointR = zoom < 5 ? 1.5 + zoom * 0.3 : 2 + zoom * 0.2;
      buildSprites(pointR);
    } else {
      buildDotSprites();
    }

    for (var i = 0; i < n; i++) {
      var px = pointsX[i], py = pointsY[i];
      if (px < xMin || px > xMax || py < yMin || py > yMax) continue;

      var sx = dataToScreenX(px), sy = dataToScreenY(py);
      var pi = platformIdx[i];

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

    // --- labels ---
    ctx.globalAlpha = 1;
    var labelColor = dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.6)';
    ctx.fillStyle = labelColor;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.shadowColor = dark ? 'rgba(0,0,0,0.8)' : 'rgba(255,255,255,0.8)';
    ctx.shadowBlur = 4;

    if (zoom < 2) {
      var fontSize = Math.max(10, 13 / zoom);
      ctx.font = fontSize + 'px monospace';
      ctx.globalAlpha = 0.8;
      for (var c = 0; c < data.clusters.coarse.length; c++) {
        var cl = data.clusters.coarse[c];
        var sx = dataToScreenX(cl.cx), sy = dataToScreenY(cl.cy);
        if (sx < -50 || sx > W + 50 || sy < -20 || sy > H + 20) continue;
        ctx.fillText(cl.label, sx, sy - Math.sqrt(cl.count) * 1.5);
      }
    } else if (zoom < 5) {
      var fontSize = Math.max(9, 11 / (zoom * 0.5));
      ctx.font = fontSize + 'px monospace';
      ctx.globalAlpha = 0.7;
      for (var c = 0; c < data.clusters.fine.length; c++) {
        var cl = data.clusters.fine[c];
        if (cl.cx < xMin || cl.cx > xMax || cl.cy < yMin || cl.cy > yMax) continue;
        var sx = dataToScreenX(cl.cx), sy = dataToScreenY(cl.cy);
        if (sx < -50 || sx > W + 50 || sy < -20 || sy > H + 20) continue;
        ctx.fillText(cl.label, sx, sy - 12);
      }
    } else {
      var fontSize = Math.min(12, 10 / (zoom * 0.15));
      ctx.font = fontSize + 'px monospace';
      ctx.globalAlpha = 0.6;
      var shown = 0, maxLabels = 60;
      for (var i = 0; i < n && shown < maxLabels; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;
        var title = data.points[i].title;
        if (!title) continue;
        var sx = dataToScreenX(px), sy = dataToScreenY(py);
        if (sx < 0 || sx > W || sy < 0 || sy > H) continue;
        if (title.length > 40) title = title.substring(0, 38) + '\u2026';
        ctx.fillText(title, sx, sy - (useGlow ? sprites[0].normal.height / (2 * dpr) : 4) - 4);
        shown++;
      }
    }

    ctx.shadowBlur = 0;
    ctx.globalAlpha = 1;
  }

  // --- animation loop ---
  function loop() {
    render();
    requestAnimationFrame(loop);
  }

  // --- hover state ---
  var hoveredIndex = -1;
  var hoverTimer = null;
  var mouseX = 0, mouseY = 0;

  // --- interaction state ---
  var dragging = false;
  var dragStartX, dragStartY, dragStartPanX, dragStartPanY;
  var pinchStartDist = 0, pinchStartZoom = 1;

  // --- interaction: mouse ---
  canvas.addEventListener('wheel', function(e) {
    e.preventDefault();
    var factor = e.deltaY > 0 ? 0.9 : 1.1;
    var newZoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * factor));
    var d = screenToData(e.clientX, e.clientY);
    view.zoom = newZoom;
    var d2 = screenToData(e.clientX, e.clientY);
    view.panX += d2[0] - d[0];
    view.panY += d2[1] - d[1];
    view.dirty = true;
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
      var scale = Math.min(W, H) * 0.42 * view.zoom;
      view.panX = dragStartPanX + (e.clientX - dragStartX) / scale;
      view.panY = dragStartPanY + (e.clientY - dragStartY) / scale;
      view.dirty = true;
      hideTooltip();
      return;
    }
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(function() {
      var idx = findNearest(mouseX, mouseY, 20);
      if (idx !== hoveredIndex) {
        hoveredIndex = idx;
        view.dirty = true;
        if (idx >= 0) showTooltip(idx, mouseX, mouseY);
        else hideTooltip();
      }
    }, 100);
  });

  window.addEventListener('mouseup', function(e) {
    if (dragging) {
      if (Math.abs(e.clientX - dragStartX) < 4 && Math.abs(e.clientY - dragStartY) < 4 && hoveredIndex >= 0) {
        var p = data.points[hoveredIndex];
        var url = atUriToUrl(p.uri, p.basePath, p.platform);
        if (url) window.open(url, '_blank');
      }
      dragging = false;
    }
  });

  // --- touch ---
  var touches = {};

  canvas.addEventListener('touchstart', function(e) {
    e.preventDefault();
    for (var i = 0; i < e.changedTouches.length; i++) {
      var t = e.changedTouches[i];
      touches[t.identifier] = { x: t.clientX, y: t.clientY };
    }
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
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', function(e) {
    e.preventDefault();
    for (var i = 0; i < e.changedTouches.length; i++) {
      var t = e.changedTouches[i];
      touches[t.identifier] = { x: t.clientX, y: t.clientY };
    }
    var ids = Object.keys(touches);
    if (ids.length === 1 && dragging) {
      var scale = Math.min(W, H) * 0.42 * view.zoom;
      view.panX = dragStartPanX + (touches[ids[0]].x - dragStartX) / scale;
      view.panY = dragStartPanY + (touches[ids[0]].y - dragStartY) / scale;
      view.dirty = true;
    } else if (ids.length === 2) {
      var a = touches[ids[0]], b = touches[ids[1]];
      var dist = Math.hypot(a.x - b.x, a.y - b.y);
      view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, pinchStartZoom * (dist / pinchStartDist)));
      view.dirty = true;
    }
  }, { passive: false });

  canvas.addEventListener('touchend', function(e) {
    for (var i = 0; i < e.changedTouches.length; i++) delete touches[e.changedTouches[i].identifier];
    if (Object.keys(touches).length === 0) dragging = false;
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
    var c = getColors()[p.platform] || getColors().other;
    tooltipPlatform.style.background = c.edge;
    tooltipPlatform.style.color = c.core;
    tooltip.style.display = 'block';
    var tw = tooltip.offsetWidth, th = tooltip.offsetHeight;
    var tx = sx + 16, ty = sy - th - 8;
    if (tx + tw > W - 10) tx = sx - tw - 16;
    if (ty < 10) ty = sy + 16;
    tooltip.style.left = tx + 'px';
    tooltip.style.top = ty + 'px';
    canvas.style.cursor = 'pointer';
  }

  function hideTooltip() {
    tooltip.style.display = 'none';
    hoveredIndex = -1;
    canvas.style.cursor = dragging ? 'grabbing' : 'grab';
  }

  // --- AT URI to URL ---
  function atUriToUrl(uri, basePath, platform) {
    var m = uri.match(/^at:\/\/(did:[^/]+)\/([^/]+)\/(.+)$/);
    if (!m) return null;
    var did = m[1], collection = m[2], rkey = m[3];
    if (platform === 'whitewind' || collection.startsWith('com.whtwnd.')) return 'https://whtwnd.com/' + did + '/' + rkey;
    if (basePath) return 'https://' + basePath + '/' + rkey;
    return 'https://pds.pub/at/' + encodeURIComponent(uri);
  }

  // --- legend ---
  function renderLegend() {
    var el = document.getElementById('legend');
    var colors = getColors();
    var html = '';
    for (var i = 0; i < PLATFORMS.length; i++) {
      html += '<div class="legend-item"><span class="legend-dot" style="background:' + colors[PLATFORMS[i]].mid + '"></span>' + PLATFORMS[i] + '</div>';
    }
    el.innerHTML = html;
  }

  // --- load data ---
  function loadData() {
    fetch('constellation.json')
      .then(function(r) {
        if (!r.ok) throw new Error('failed to load constellation.json: ' + r.status);
        return r.json();
      })
      .then(function(d) {
        data = d;
        var n = d.points.length;
        pointsX = new Float32Array(n);
        pointsY = new Float32Array(n);
        platformIdx = new Uint8Array(n);

        // build platform lookup
        var platMap = {};
        for (var p = 0; p < PLATFORMS.length; p++) platMap[PLATFORMS[p]] = p;
        var otherIdx = platMap.other;

        for (var i = 0; i < n; i++) {
          pointsX[i] = d.points[i].x;
          pointsY[i] = d.points[i].y;
          platformIdx[i] = platMap[d.points[i].platform] !== undefined ? platMap[d.points[i].platform] : otherIdx;
        }

        buildSpatialIndex();
        renderLegend();

        document.getElementById('stats').textContent =
          n.toLocaleString() + ' documents \u00B7 ' +
          d.clusters.coarse.length + ' regions \u00B7 ' +
          d.clusters.fine.length + ' clusters';

        document.getElementById('loading').classList.add('hidden');
        view.dirty = true;
      })
      .catch(function(err) {
        document.getElementById('loading').querySelector('.spinner').textContent = 'error: ' + err.message;
        console.error(err);
      });
  }

  // --- init ---
  window.addEventListener('resize', resizeCanvas);
  resizeCanvas();
  loadData();
  loop();

  window.constellation = {
    setDirty: function() {
      sprites = null;
      dotSprites = null;
      renderLegend();
      view.dirty = true;
    }
  };
})();
