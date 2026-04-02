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

  // light theme overrides (darker cores for visibility)
  var PLATFORM_COLORS_LIGHT = {
    leaflet:   { core: '#16a34a', mid: '#15803d', edge: '#a7f3d0' },
    whitewind: { core: '#2563eb', mid: '#1d4ed8', edge: '#bfdbfe' },
    pckt:      { core: '#d97706', mid: '#b45309', edge: '#fde68a' },
    offprint:  { core: '#e11d48', mid: '#be123c', edge: '#fecdd3' },
    greengale: { core: '#0d9488', mid: '#0f766e', edge: '#99f6e4' },
    other:     { core: '#4b5563', mid: '#374151', edge: '#d1d5db' },
  };

  function getColors() {
    var theme = document.documentElement.getAttribute('data-theme');
    return theme === 'light' ? PLATFORM_COLORS_LIGHT : PLATFORM_COLORS;
  }

  function isDark() {
    return document.documentElement.getAttribute('data-theme') !== 'light';
  }

  // --- view state ---
  var view = {
    zoom: 1,
    panX: 0,
    panY: 0,
    minZoom: 0.5,
    maxZoom: 15,
    dirty: true,
  };

  // --- data ---
  var data = null;
  var pointsX = null;  // Float32Array
  var pointsY = null;
  var gridIndex = null; // spatial index for hover

  // --- canvas ---
  var canvas = document.getElementById('canvas');
  var ctx = canvas.getContext('2d');
  var dpr = window.devicePixelRatio || 1;
  var W, H;

  // --- hover state ---
  var hoveredIndex = -1;
  var hoverTimer = null;
  var mouseX = 0, mouseY = 0;

  // --- interaction state ---
  var dragging = false;
  var dragStartX, dragStartY;
  var dragStartPanX, dragStartPanY;
  var pinchStartDist = 0;
  var pinchStartZoom = 1;

  // --- gradient cache ---
  var gradientCache = {};

  function resizeCanvas() {
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    gradientCache = {};
    view.dirty = true;
  }

  // --- coordinate transforms ---
  function dataToScreen(dx, dy) {
    var cx = W / 2;
    var cy = H / 2;
    var scale = Math.min(W, H) * 0.42 * view.zoom;
    return [
      cx + (dx + view.panX) * scale,
      cy + (dy + view.panY) * scale,
    ];
  }

  function screenToData(sx, sy) {
    var cx = W / 2;
    var cy = H / 2;
    var scale = Math.min(W, H) * 0.42 * view.zoom;
    return [
      (sx - cx) / scale - view.panX,
      (sy - cy) / scale - view.panY,
    ];
  }

  // --- spatial index (grid-based) ---
  function buildSpatialIndex() {
    if (!data) return;
    var cellSize = 0.02; // in data space
    gridIndex = { cellSize: cellSize, cells: {} };
    for (var i = 0; i < data.points.length; i++) {
      var gx = Math.floor(pointsX[i] / cellSize);
      var gy = Math.floor(pointsY[i] / cellSize);
      var key = gx + ',' + gy;
      if (!gridIndex.cells[key]) gridIndex.cells[key] = [];
      gridIndex.cells[key].push(i);
    }
  }

  function findNearest(sx, sy, maxDist) {
    if (!gridIndex) return -1;
    var d = screenToData(sx, sy);
    var dx = d[0], dy = d[1];
    var scale = Math.min(W, H) * 0.42 * view.zoom;
    var searchRadius = maxDist / scale;
    var cs = gridIndex.cellSize;
    var gxMin = Math.floor((dx - searchRadius) / cs);
    var gxMax = Math.floor((dx + searchRadius) / cs);
    var gyMin = Math.floor((dy - searchRadius) / cs);
    var gyMax = Math.floor((dy + searchRadius) / cs);

    var bestIdx = -1;
    var bestDist = searchRadius * searchRadius;

    for (var gx = gxMin; gx <= gxMax; gx++) {
      for (var gy = gyMin; gy <= gyMax; gy++) {
        var cell = gridIndex.cells[gx + ',' + gy];
        if (!cell) continue;
        for (var k = 0; k < cell.length; k++) {
          var i = cell[k];
          var ddx = pointsX[i] - dx;
          var ddy = pointsY[i] - dy;
          var dist2 = ddx * ddx + ddy * ddy;
          if (dist2 < bestDist) {
            bestDist = dist2;
            bestIdx = i;
          }
        }
      }
    }
    return bestIdx;
  }

  // --- rendering ---
  function getPointRadius(zoom) {
    if (zoom < 2) return 1.8;
    if (zoom < 5) return 1.5 + zoom * 0.3;
    return 2 + zoom * 0.2;
  }

  function drawPoint(x, y, r, colors, alpha) {
    if (r < 1.5) {
      // tiny points: simple filled circle
      ctx.globalAlpha = alpha;
      ctx.fillStyle = colors.mid;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fill();
      return;
    }

    // celestial body: radial gradient
    var cacheKey = colors.core + '_' + Math.round(r * 10);
    var grad = gradientCache[cacheKey];
    if (!grad) {
      grad = ctx.createRadialGradient(x, y, 0, x, y, r * 2.5);
      grad.addColorStop(0, colors.core);
      grad.addColorStop(0.3, colors.mid);
      grad.addColorStop(0.7, colors.edge);
      grad.addColorStop(1, 'transparent');
      // don't cache position-dependent gradients for large radii
    }

    // for larger radii, always create fresh (position-dependent)
    grad = ctx.createRadialGradient(x, y, 0, x, y, r * 2.5);
    grad.addColorStop(0, colors.core);
    grad.addColorStop(0.3, colors.mid);
    grad.addColorStop(0.7, colors.edge);
    grad.addColorStop(1, 'transparent');

    ctx.globalAlpha = alpha;
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(x, y, r * 2.5, 0, Math.PI * 2);
    ctx.fill();

    // bright core
    ctx.globalAlpha = alpha * 0.9;
    ctx.fillStyle = colors.core;
    ctx.beginPath();
    ctx.arc(x, y, r * 0.5, 0, Math.PI * 2);
    ctx.fill();
  }

  function drawClusterGlow(cx, cy, count, alpha) {
    var r = Math.sqrt(count) * 2;
    var grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
    var dark = isDark();
    grad.addColorStop(0, dark ? 'rgba(255,255,255,0.03)' : 'rgba(0,0,0,0.02)');
    grad.addColorStop(1, 'transparent');
    ctx.globalAlpha = alpha;
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fill();
  }

  function drawLabel(text, sx, sy, fontSize, alpha) {
    ctx.globalAlpha = alpha;
    var dark = isDark();
    ctx.fillStyle = dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.6)';
    ctx.font = fontSize + 'px monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    // text shadow for readability
    if (dark) {
      ctx.shadowColor = 'rgba(0,0,0,0.8)';
      ctx.shadowBlur = 4;
    } else {
      ctx.shadowColor = 'rgba(255,255,255,0.8)';
      ctx.shadowBlur = 4;
    }
    ctx.fillText(text, sx, sy);
    ctx.shadowBlur = 0;
  }

  function render() {
    if (!data || !view.dirty) return;
    view.dirty = false;

    var dark = isDark();
    ctx.clearRect(0, 0, W, H);

    // background
    ctx.fillStyle = dark ? '#050505' : '#f5f5f0';
    ctx.fillRect(0, 0, W, H);

    var zoom = view.zoom;
    var scale = Math.min(W, H) * 0.42 * zoom;
    var colors = getColors();
    var r = getPointRadius(zoom);

    // visible bounds in data space
    var tl = screenToData(0, 0);
    var br = screenToData(W, H);
    var pad = 0.05;
    var xMin = tl[0] - pad, xMax = br[0] + pad;
    var yMin = tl[1] - pad, yMax = br[1] + pad;

    // --- cluster glows (zoomed out) ---
    if (zoom < 4) {
      var clusters = zoom < 2 ? data.clusters.coarse : data.clusters.fine;
      for (var c = 0; c < clusters.length; c++) {
        var cl = clusters[c];
        var sp = dataToScreen(cl.cx, cl.cy);
        if (sp[0] < -100 || sp[0] > W + 100 || sp[1] < -100 || sp[1] > H + 100) continue;
        drawClusterGlow(sp[0], sp[1], cl.count, zoom < 2 ? 0.6 : 0.3);
      }
    }

    // --- points ---
    var points = data.points;
    var n = points.length;
    ctx.globalAlpha = 1;

    for (var i = 0; i < n; i++) {
      var px = pointsX[i];
      var py = pointsY[i];
      if (px < xMin || px > xMax || py < yMin || py > yMax) continue;

      var sp = dataToScreen(px, py);
      var platform = points[i].platform || 'other';
      var c = colors[platform] || colors.other;
      var alpha = (i === hoveredIndex) ? 1.0 : (zoom > 3 ? 0.85 : 0.7);
      drawPoint(sp[0], sp[1], (i === hoveredIndex) ? r * 2 : r, c, alpha);
    }

    // --- labels ---
    ctx.globalAlpha = 1;

    if (zoom < 2) {
      // coarse cluster labels
      var fontSize = Math.max(10, 13 / zoom);
      for (var c = 0; c < data.clusters.coarse.length; c++) {
        var cl = data.clusters.coarse[c];
        var sp = dataToScreen(cl.cx, cl.cy);
        if (sp[0] < -50 || sp[0] > W + 50 || sp[1] < -20 || sp[1] > H + 20) continue;
        drawLabel(cl.label, sp[0], sp[1] - Math.sqrt(cl.count) * 1.5, fontSize, 0.8);
      }
    } else if (zoom < 5) {
      // fine cluster labels
      var fontSize = Math.max(9, 11 / (zoom * 0.5));
      for (var c = 0; c < data.clusters.fine.length; c++) {
        var cl = data.clusters.fine[c];
        if (cl.cx < xMin || cl.cx > xMax || cl.cy < yMin || cl.cy > yMax) continue;
        var sp = dataToScreen(cl.cx, cl.cy);
        if (sp[0] < -50 || sp[0] > W + 50 || sp[1] < -20 || sp[1] > H + 20) continue;
        drawLabel(cl.label, sp[0], sp[1] - 12, fontSize, 0.7);
      }
    } else {
      // individual document titles
      var fontSize = Math.min(12, 10 / (zoom * 0.15));
      var shown = 0;
      var maxLabels = 60;
      for (var i = 0; i < n && shown < maxLabels; i++) {
        var px = pointsX[i];
        var py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;
        var title = points[i].title;
        if (!title) continue;
        var sp = dataToScreen(px, py);
        if (sp[0] < 0 || sp[0] > W || sp[1] < 0 || sp[1] > H) continue;
        // truncate long titles
        if (title.length > 40) title = title.substring(0, 38) + '\u2026';
        drawLabel(title, sp[0], sp[1] - r * 3 - 4, fontSize, 0.6);
        shown++;
      }
    }

    ctx.globalAlpha = 1;
  }

  // --- animation loop ---
  function loop() {
    render();
    requestAnimationFrame(loop);
  }

  // --- interaction: mouse ---
  canvas.addEventListener('wheel', function(e) {
    e.preventDefault();
    var factor = e.deltaY > 0 ? 0.9 : 1.1;
    var newZoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * factor));

    // zoom toward cursor
    var d = screenToData(e.clientX, e.clientY);
    view.zoom = newZoom;
    var d2 = screenToData(e.clientX, e.clientY);
    view.panX += d2[0] - d[0];
    view.panY += d2[1] - d[1];

    view.dirty = true;
    gradientCache = {};
  }, { passive: false });

  canvas.addEventListener('mousedown', function(e) {
    if (e.button !== 0) return;
    dragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    dragStartPanX = view.panX;
    dragStartPanY = view.panY;
  });

  window.addEventListener('mousemove', function(e) {
    mouseX = e.clientX;
    mouseY = e.clientY;

    if (dragging) {
      var scale = Math.min(W, H) * 0.42 * view.zoom;
      view.panX = dragStartPanX + (e.clientX - dragStartX) / scale;
      view.panY = dragStartPanY + (e.clientY - dragStartY) / scale;
      view.dirty = true;
      hideTooltip();
      return;
    }

    // hover with delay
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(function() {
      var idx = findNearest(mouseX, mouseY, 20);
      if (idx !== hoveredIndex) {
        hoveredIndex = idx;
        view.dirty = true;
        if (idx >= 0) {
          showTooltip(idx, mouseX, mouseY);
        } else {
          hideTooltip();
        }
      }
    }, 100);
  });

  window.addEventListener('mouseup', function(e) {
    if (dragging) {
      var dx = Math.abs(e.clientX - dragStartX);
      var dy = Math.abs(e.clientY - dragStartY);
      // click detection: small drag = click
      if (dx < 4 && dy < 4 && hoveredIndex >= 0) {
        var p = data.points[hoveredIndex];
        var url = atUriToUrl(p.uri, p.basePath, p.platform);
        if (url) window.open(url, '_blank');
      }
      dragging = false;
    }
  });

  // --- interaction: touch ---
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
      dragStartX = touches[ids[0]].x;
      dragStartY = touches[ids[0]].y;
      dragStartPanX = view.panX;
      dragStartPanY = view.panY;
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
      var newZoom = pinchStartZoom * (dist / pinchStartDist);
      view.zoom = Math.max(view.minZoom, Math.min(view.maxZoom, newZoom));
      view.dirty = true;
      gradientCache = {};
    }
  }, { passive: false });

  canvas.addEventListener('touchend', function(e) {
    for (var i = 0; i < e.changedTouches.length; i++) {
      delete touches[e.changedTouches[i].identifier];
    }
    if (Object.keys(touches).length === 0) {
      dragging = false;
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
    var colors = getColors();
    var c = colors[p.platform] || colors.other;
    tooltipPlatform.style.background = c.edge;
    tooltipPlatform.style.color = c.core;

    tooltip.style.display = 'block';
    // position: avoid going off screen
    var tw = tooltip.offsetWidth;
    var th = tooltip.offsetHeight;
    var tx = sx + 16;
    var ty = sy - th - 8;
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
    // at://did:plc:xxx/collection/rkey
    var m = uri.match(/^at:\/\/(did:[^/]+)\/([^/]+)\/(.+)$/);
    if (!m) return null;
    var did = m[1], collection = m[2], rkey = m[3];

    if (platform === 'whitewind' || collection.startsWith('com.whtwnd.')) {
      return 'https://whtwnd.com/' + did + '/' + rkey;
    }
    if (basePath) {
      return 'https://' + basePath + '/' + rkey;
    }
    // fallback: try to construct a reasonable URL
    return 'https://pds.pub/at/' + encodeURIComponent(uri);
  }

  // --- legend ---
  function renderLegend() {
    var el = document.getElementById('legend');
    var colors = getColors();
    var html = '';
    var platforms = ['leaflet', 'whitewind', 'pckt', 'offprint', 'greengale', 'other'];
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i];
      var c = colors[p];
      html += '<div class="legend-item"><span class="legend-dot" style="background:' + c.mid + '"></span>' + p + '</div>';
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

        // build typed arrays
        var n = d.points.length;
        pointsX = new Float32Array(n);
        pointsY = new Float32Array(n);
        for (var i = 0; i < n; i++) {
          pointsX[i] = d.points[i].x;
          pointsY[i] = d.points[i].y;
        }

        buildSpatialIndex();
        renderLegend();

        // stats
        document.getElementById('stats').textContent =
          n.toLocaleString() + ' documents \u00B7 ' +
          d.clusters.coarse.length + ' regions \u00B7 ' +
          d.clusters.fine.length + ' clusters';

        // hide loading
        document.getElementById('loading').classList.add('hidden');

        view.dirty = true;
      })
      .catch(function(err) {
        document.getElementById('loading').querySelector('.spinner').textContent =
          'error: ' + err.message;
        console.error(err);
      });
  }

  // --- init ---
  window.addEventListener('resize', resizeCanvas);
  resizeCanvas();
  loadData();
  loop();

  // expose for theme toggle
  window.constellation = {
    setDirty: function() {
      gradientCache = {};
      renderLegend();
      view.dirty = true;
    }
  };
})();
