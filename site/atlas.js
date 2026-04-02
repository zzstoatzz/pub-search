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
  var pointsX = null;
  var pointsY = null;
  var platformIdx = null;
  var gridIndex = null;
  var uriToIndex = null; // Map<uri, index> for search matching

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
    var size = Math.ceil(radius * 6 * dpr) + 2;
    if (size < 4) size = 4;
    var theme = isDark() ? 'dark' : 'light';
    if (sprites && spriteSize === size && spriteTheme === theme) return;
    spriteSize = size;
    spriteTheme = theme;
    var colors = getColors();
    sprites = [];
    for (var p = 0; p < PLATFORMS.length; p++) {
      var c = colors[PLATFORMS[p]];
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
    view.dirty = true;
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

  // --- label helper: strokeText outline instead of shadowBlur ---
  function drawLabel(text, x, y, dark) {
    ctx.strokeStyle = dark ? 'rgba(0,0,0,0.7)' : 'rgba(255,255,255,0.7)';
    ctx.lineWidth = 3;
    ctx.lineJoin = 'round';
    ctx.strokeText(text, x, y);
    ctx.fillText(text, x, y);
  }

  // --- rendering ---
  function render() {
    if (!data || !view.dirty) return;
    view.dirty = false;

    var dark = isDark();
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

    // --- cluster glows (zoomed out) ---
    if (zoom < 4) {
      var clusters = zoom < 2 ? data.clusters.coarse : data.clusters.fine;
      ctx.globalAlpha = zoom < 2 ? 0.6 : 0.3;
      for (var c = 0; c < clusters.length; c++) {
        var cl = clusters[c];
        var sx = cx + cl.cx * scale, sy = cy + cl.cy * scale;
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

    // --- connection lines (batched by opacity bucket) ---
    if (zoom >= 3 && gridIndex) {
      var connRadius = 0.025;
      var cs = gridIndex.cellSize;
      var maxLines = 1500;
      var lineCount = 0;

      // batch into 3 opacity buckets to minimize style changes
      var buckets = [[], [], []]; // near, mid, far

      for (var i = 0; i < n && lineCount < maxLines; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;

        var sx1 = cx + px * scale, sy1 = cy + py * scale;
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
              var dx = pointsX[j] - px, dy = pointsY[j] - py;
              var dist2 = dx * dx + dy * dy;
              if (dist2 > connRadius * connRadius || dist2 < 0.0001) continue;
              var t = Math.sqrt(dist2) / connRadius; // 0=close, 1=far
              var bucket = t < 0.33 ? 0 : t < 0.66 ? 1 : 2;
              buckets[bucket].push(sx1, sy1, cx + pointsX[j] * scale, cy + pointsY[j] * scale);
              lineCount++;
            }
          }
        }
      }

      // draw each bucket in one path
      var opacities = dark
        ? ['rgba(255,255,255,0.10)', 'rgba(255,255,255,0.06)', 'rgba(255,255,255,0.03)']
        : ['rgba(0,0,0,0.08)', 'rgba(0,0,0,0.05)', 'rgba(0,0,0,0.02)'];
      ctx.lineWidth = 0.5;
      for (var b = 0; b < 3; b++) {
        var buf = buckets[b];
        if (!buf.length) continue;
        ctx.beginPath();
        for (var l = 0; l < buf.length; l += 4) {
          ctx.moveTo(buf[l], buf[l + 1]);
          ctx.lineTo(buf[l + 2], buf[l + 3]);
        }
        ctx.strokeStyle = opacities[b];
        ctx.globalAlpha = 1;
        ctx.stroke();
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
      var sx = cx + px * scale, sy = cy + py * scale;
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
        // crosshair
        ctx.strokeStyle = dark ? 'rgba(255,255,255,0.5)' : 'rgba(0,0,0,0.4)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(mx - 12, my); ctx.lineTo(mx + 12, my);
        ctx.moveTo(mx, my - 12); ctx.lineTo(mx, my + 12);
        ctx.stroke();
        // ring
        ctx.beginPath();
        ctx.arc(mx, my, 6, 0, Math.PI * 2);
        ctx.strokeStyle = dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.5)';
        ctx.lineWidth = 1.5;
        ctx.stroke();
        // label
        ctx.font = '10px monospace';
        ctx.fillStyle = dark ? 'rgba(255,255,255,0.6)' : 'rgba(0,0,0,0.5)';
        ctx.textAlign = 'left';
        ctx.textBaseline = 'top';
        ctx.fillText('"' + searchQuery + '"', mx + 12, my - 6);
      }
    }

    // --- labels (no shadowBlur — uses strokeText outline instead) ---
    ctx.globalAlpha = 1;
    ctx.fillStyle = dark ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.65)';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    var small = W < 600;
    if (zoom < 2) {
      // coarse labels
      ctx.font = (small ? '9px' : '12px') + ' monospace';
      ctx.globalAlpha = 0.85;
      for (var c = 0; c < data.clusters.coarse.length; c++) {
        var cl = data.clusters.coarse[c];
        var sx = cx + cl.cx * scale, sy = cy + cl.cy * scale;
        if (sx < -50 || sx > W + 50 || sy < -20 || sy > H + 20) continue;
        drawLabel(cl.label, sx, sy - Math.sqrt(cl.count) * 1.5, dark);
      }
    } else if (zoom < 5) {
      // fine labels
      ctx.font = (small ? '8px' : '11px') + ' monospace';
      ctx.globalAlpha = 0.75;
      for (var c = 0; c < data.clusters.fine.length; c++) {
        var cl = data.clusters.fine[c];
        if (cl.cx < xMin || cl.cx > xMax || cl.cy < yMin || cl.cy > yMax) continue;
        var sx = cx + cl.cx * scale, sy = cy + cl.cy * scale;
        if (sx < -50 || sx > W + 50 || sy < -20 || sy > H + 20) continue;
        drawLabel(cl.label, sx, sy - 14, dark);
      }
    } else {
      // document titles
      ctx.font = (small ? '9px' : '11px') + ' monospace';
      ctx.globalAlpha = 0.7;
      var shown = 0, maxLabels = small ? 25 : 50;
      var truncLen = small ? 30 : 45;
      for (var i = 0; i < n && shown < maxLabels; i++) {
        var px = pointsX[i], py = pointsY[i];
        if (px < xMin || px > xMax || py < yMin || py > yMax) continue;
        var title = data.points[i].title;
        if (!title) continue;
        var sx = cx + px * scale, sy = cy + py * scale;
        if (sx < 0 || sx > W || sy < 0 || sy > H) continue;
        if (title.length > truncLen) title = title.substring(0, truncLen - 2) + '\u2026';
        drawLabel(title, sx, sy - 10, dark);
        shown++;
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
  }

  function loop() {
    tickAnimation();
    render();
    requestAnimationFrame(loop);
  }

  // --- hover state ---
  var hoveredIndex = -1;
  var mouseX = 0, mouseY = 0;

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
    var factor = e.deltaY > 0 ? 0.9 : 1.1;
    var newZoom = Math.max(view.minZoom, Math.min(view.maxZoom, view.zoom * factor));
    cacheTransform();
    var d = screenToData(e.clientX, e.clientY);
    view.zoom = newZoom;
    cacheTransform();
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
      cacheTransform();
      view.panX = dragStartPanX + (e.clientX - dragStartX) / scale;
      view.panY = dragStartPanY + (e.clientY - dragStartY) / scale;
      view.dirty = true;
      hideTooltip();
      return;
    }
    cacheTransform();
    var idx = findNearest(mouseX, mouseY, HIT_RADIUS);
    if (idx !== hoveredIndex) {
      hoveredIndex = idx;
      view.dirty = true;
      if (idx >= 0) showTooltip(idx, mouseX, mouseY);
      else hideTooltip();
    }
  });

  window.addEventListener('mouseup', function(e) {
    if (dragging) {
      if (Math.abs(e.clientX - dragStartX) < 4 && Math.abs(e.clientY - dragStartY) < 4 && hoveredIndex >= 0) {
        var p = data.points[hoveredIndex];
        var url = atUriToUrl(p.uri, p.basePath, p.platform, p.path);
        if (url) window.open(url, '_blank');
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
      view.dirty = true;
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
      view.dirty = true;
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
        var idx = findNearest(tx, ty, HIT_RADIUS);
        if (idx >= 0) {
          if (idx === selectedIndex) {
            // second tap on same point — open URL
            var p = data.points[idx];
            var url = atUriToUrl(p.uri, p.basePath, p.platform, p.path);
            if (url) window.open(url, '_blank');
            selectedIndex = -1;
            hideTooltip();
          } else {
            // first tap — show tooltip
            selectedIndex = idx;
            hoveredIndex = idx;
            showTooltip(idx, tx, ty);
            view.dirty = true;
          }
        } else {
          // tapped empty space — dismiss
          selectedIndex = -1;
          hideTooltip();
          view.dirty = true;
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
    var c = getColors()[p.platform] || getColors().other;
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
    canvas.style.cursor = dragging ? 'grabbing' : 'grab';
  }

  function atUriToUrl(uri, basePath, platform, path) {
    var m = uri.match(/^at:\/\/(did:[^/]+)\/([^/]+)\/(.+)$/);
    if (!m) return null;
    var did = m[1], collection = m[2], rkey = m[3];
    if (platform === 'whitewind' || collection.startsWith('com.whtwnd.')) return 'https://whtwnd.com/' + did + '/' + rkey;
    // leaflet uses rkey directly
    if (platform === 'leaflet' && basePath) return 'https://' + basePath + '/' + rkey;
    // leaflet without basePath
    if (platform === 'leaflet') return 'https://leaflet.pub/p/' + did + '/' + rkey;
    // other platforms (pckt, offprint, etc.) use path slug when available
    if (basePath && path) {
      var sep = path.charAt(0) === '/' ? '' : '/';
      return 'https://' + basePath + sep + path;
    }
    if (basePath) return 'https://' + basePath + '/' + rkey;
    // universal fallback — AT Protocol record viewer
    return 'https://pdsls.dev/at/' + did + '/' + collection + '/' + rkey;
  }

  function renderLegend() {
    var el = document.getElementById('legend');
    var colors = getColors();
    var html = '';
    for (var i = 0; i < PLATFORMS.length; i++) {
      html += '<div class="legend-item"><span class="legend-dot" style="background:' + colors[PLATFORMS[i]].mid + '"></span>' + PLATFORMS[i] + '</div>';
    }
    el.innerHTML = html;
  }

  function loadData() {
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

  window.addEventListener('resize', resizeCanvas);
  resizeCanvas();
  loadData();
  loop();

  // --- search ---
  var API_URL = 'https://leaflet-search-backend.fly.dev';
  var searchInput = document.getElementById('search-input');
  var searchForm = document.getElementById('search-form');
  var searchStatusEl = null;

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
    view.dirty = true;
  }

  function doSearch(query) {
    if (!query || !data || !uriToIndex) return;
    searchQuery = query;
    setSearchStatus('searching...');

    fetch(API_URL + '/search?mode=semantic&limit=20&format=v2&q=' + encodeURIComponent(query))
      .then(function(r) {
        if (!r.ok) throw new Error('search failed: ' + r.status);
        return r.json();
      })
      .then(function(resp) {
        var results = resp.results || [];
        if (results.length === 0) {
          setSearchStatus('no results');
          searchMatches = null;
          searchCenter = null;
          view.dirty = true;
          return;
        }

        // match result URIs to atlas points
        var matches = new Set();
        var weightedX = 0, weightedY = 0, totalWeight = 0;
        for (var i = 0; i < results.length; i++) {
          var uri = results[i].uri;
          if (uriToIndex.has(uri)) {
            var idx = uriToIndex.get(uri);
            matches.add(idx);
            // weight by rank (higher rank = more weight)
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
          view.dirty = true;
          return;
        }

        searchMatches = matches;
        searchCenter = { x: weightedX / totalWeight, y: weightedY / totalWeight };
        setSearchStatus(matches.size + ' of ' + results.length + ' on map');

        // compute spread to determine zoom level
        var maxDist = 0;
        matches.forEach(function(idx) {
          var dx = pointsX[idx] - searchCenter.x;
          var dy = pointsY[idx] - searchCenter.y;
          var d = Math.sqrt(dx * dx + dy * dy);
          if (d > maxDist) maxDist = d;
        });

        // zoom to fit the spread with some padding
        // at zoom=1, visible radius in data coords is ~1.0 (since range is [-1,1])
        // we want maxDist to fit in ~40% of the viewport
        var targetZoom = maxDist > 0 ? Math.min(view.maxZoom, 0.4 / maxDist) : 4;
        targetZoom = Math.max(2, Math.min(8, targetZoom)); // clamp to reasonable range

        animateTo(searchCenter.x, searchCenter.y, targetZoom);
      })
      .catch(function(err) {
        setSearchStatus('error');
        console.error(err);
      });
  }

  searchForm.addEventListener('submit', function(e) {
    e.preventDefault();
    var q = searchInput.value.trim();
    if (q) doSearch(q);
    else clearSearch();
  });

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
      renderLegend();
      view.dirty = true;
    }
  };
})();
