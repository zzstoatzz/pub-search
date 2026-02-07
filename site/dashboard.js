const API_BASE = 'https://leaflet-search-backend.fly.dev';

let startedAt = 0;

// loading state handler
const loader = createLoader({
  container: '.container',
  wakeThreshold: 2000,
});

function formatAge(ms) {
  const s = Math.floor(ms / 1000);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (d > 0) return d + 'd ' + h + 'h ' + m + 'm ' + sec + 's';
  if (h > 0) return h + 'h ' + m + 'm ' + sec + 's';
  return m + 'm ' + sec + 's';
}

function updateAge() {
  if (startedAt > 0) {
    document.getElementById('age').textContent = formatAge(Date.now() - startedAt);
  }
}

function renderTimeline(timeline) {
  const el = document.getElementById('timeline');
  if (!timeline || timeline.length === 0) return;

  const max = Math.max(...timeline.map(d => d.count));
  [...timeline].reverse().forEach(d => {
    const h = max > 0 ? (d.count / max * 100) : 0;
    const bar = document.createElement('div');
    bar.className = 'bar';
    bar.style.height = Math.max(h, 3) + '%';
    bar.title = d.date + ': ' + d.count;
    el.appendChild(bar);
  });
}

function renderPubs(pubs) {
  const el = document.getElementById('pubs');
  if (!pubs) return;

  pubs.forEach(p => {
    const row = document.createElement('div');
    row.className = 'pub-row';
    const nameHtml = p.basePath
      ? '<a href="https://' + escapeHtml(p.basePath) + '" target="_blank" class="pub-name">' + escapeHtml(p.name) + '</a>'
      : '<span class="pub-name">' + escapeHtml(p.name) + '</span>';
    row.innerHTML = nameHtml + '<span class="pub-count">' + p.count + '</span>';
    el.appendChild(row);
  });
}

function renderTags(tags) {
  const el = document.getElementById('tags');
  if (!tags) return;

  el.innerHTML = tags.slice(0, 20).map(t =>
    '<a class="tag" href="https://pub-search.waow.tech/?tag=' + encodeURIComponent(t.tag) + '">' +
      escapeHtml(t.tag) + '<span class="n">' + t.count + '</span></a>'
  ).join('');
}

function renderPlatforms(platforms) {
  const el = document.getElementById('platforms');
  if (!platforms) return;

  platforms.forEach(p => {
    const row = document.createElement('div');
    row.className = 'doc-row';
    row.innerHTML = '<span class="doc-type">' + escapeHtml(p.platform) + '</span><span class="doc-count">' + p.count + '</span>';
    el.appendChild(row);
  });
}

function formatMs(ms) {
  if (ms >= 1000) return (ms / 1000).toFixed(1) + 's';
  if (ms >= 10) return ms.toFixed(0) + 'ms';
  if (ms >= 1) return ms.toFixed(1) + 'ms';
  return Math.round(ms * 1000) + 'µs';
}

const ENDPOINT_COLORS = {
  search_keyword: '#3b82f6',
  search_semantic: '#8b5cf6',
  search_hybrid: '#10b981',
  similar: '#06b6d4',
  tags: '#f59e0b',
  popular: '#f97316',
};

const ENDPOINT_LABELS = {
  search_keyword: 'keyword',
  search_semantic: 'semantic',
  search_hybrid: 'hybrid',
  similar: 'similar',
  tags: 'tags',
  popular: 'popular',
};

function renderTiming(timing) {
  const el = document.getElementById('timing');
  if (!timing) return;

  const endpoints = ['search_keyword', 'search_semantic', 'search_hybrid', 'similar', 'tags', 'popular'];
  endpoints.forEach(name => {
    const t = timing[name];
    if (!t) return;

    const row = document.createElement('div');
    row.className = 'timing-row';
    const color = ENDPOINT_COLORS[name];
    const label = ENDPOINT_LABELS[name] || name;

    if (t.count === 0) {
      row.innerHTML = '<span class="timing-name" style="color:' + color + '">' + label + '</span><span class="timing-value dim">--</span>';
    } else {
      row.innerHTML = '<span class="timing-name" style="color:' + color + '">' + label + '</span>' +
        '<span class="timing-value">' + formatMs(t.p50_ms) + ' <span class="dim">p50</span> · ' +
        formatMs(t.p95_ms) + ' <span class="dim">p95</span></span>';
    }
    el.appendChild(row);
  });

  // render line chart for history
  renderLatencyChart(timing);
}

function renderLatencyChart(timing) {
  const container = document.getElementById('latency-history');
  if (!container) return;

  const endpoints = ['search_keyword', 'search_semantic', 'search_hybrid', 'similar', 'tags', 'popular'];

  // check if any endpoint has history data
  const hasData = endpoints.some(name => timing[name]?.history?.some(h => h.count > 0));
  if (!hasData) {
    container.innerHTML = '<div style="color:#444;font-size:11px;text-align:center;padding:2rem">no data yet</div>';
    return;
  }

  // create a grid of mini-charts, each with its own scale
  const grid = document.createElement('div');
  grid.className = 'latency-grid';
  container.appendChild(grid);

  endpoints.forEach(name => {
    const history = timing[name]?.history || [];
    const color = ENDPOINT_COLORS[name];

    // find max for this endpoint only
    let maxVal = 0;
    history.forEach(p => { if (p.avg_ms > maxVal) maxVal = p.avg_ms; });
    if (maxVal === 0) maxVal = 100;

    const cell = document.createElement('div');
    cell.className = 'latency-cell';

    const friendlyName = ENDPOINT_LABELS[name] || name;
    const label = document.createElement('div');
    label.className = 'latency-cell-label';
    label.innerHTML = '<span class="dot" style="background:' + color + '"></span>' + friendlyName +
      '<span class="latency-cell-max">' + formatMs(maxVal) + '</span>';
    cell.appendChild(label);

    if (history.length === 0 || !history.some(h => h.count > 0)) {
      const empty = document.createElement('div');
      empty.className = 'latency-cell-empty';
      empty.textContent = '--';
      cell.appendChild(empty);
      grid.appendChild(cell);
      return;
    }

    const canvasWrap = document.createElement('div');
    canvasWrap.className = 'latency-canvas-wrap';
    const canvas = document.createElement('canvas');
    const tooltip = document.createElement('div');
    tooltip.className = 'latency-tooltip';
    canvasWrap.appendChild(canvas);
    canvasWrap.appendChild(tooltip);
    cell.appendChild(canvasWrap);
    grid.appendChild(cell);

    // draw after append so we can measure
    requestAnimationFrame(() => {
      const ctx = canvas.getContext('2d');
      const dpr = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      canvas.width = rect.width * dpr;
      canvas.height = rect.height * dpr;
      ctx.scale(dpr, dpr);

      const w = rect.width;
      const h = rect.height;
      const padding = { top: 2, right: 2, bottom: 2, left: 2 };
      const chartW = w - padding.left - padding.right;
      const chartH = h - padding.top - padding.bottom;

      const points = history.map((p, i) => ({
        x: padding.left + (i / Math.max(history.length - 1, 1)) * chartW,
        y: padding.top + chartH - (p.avg_ms / maxVal) * chartH
      }));

      // draw filled area
      ctx.beginPath();
      ctx.moveTo(points[0].x, padding.top + chartH);
      points.forEach(p => ctx.lineTo(p.x, p.y));
      ctx.lineTo(points[points.length - 1].x, padding.top + chartH);
      ctx.closePath();
      ctx.fillStyle = color + '20';
      ctx.fill();

      // draw line
      ctx.beginPath();
      ctx.moveTo(points[0].x, points[0].y);
      for (let i = 1; i < points.length; i++) {
        ctx.lineTo(points[i].x, points[i].y);
      }
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // hover interaction
      canvas.addEventListener('mousemove', e => {
        const canvasRect = canvas.getBoundingClientRect();
        const mouseX = e.clientX - canvasRect.left;
        const idx = Math.round((mouseX - padding.left) / chartW * (history.length - 1));
        const clampedIdx = Math.max(0, Math.min(history.length - 1, idx));
        const point = history[clampedIdx];
        if (point) {
          const time = formatTimestamp(point.hour);
          tooltip.textContent = time + ' · ' + formatMs(point.avg_ms);
          tooltip.style.opacity = '1';
        }
      });
      canvas.addEventListener('mouseleave', () => {
        tooltip.style.opacity = '0';
      });
    });
  });
}

function formatTimestamp(hour) {
  const d = new Date(hour * 1000);
  const h = d.getHours();
  const ampm = h >= 12 ? 'pm' : 'am';
  const h12 = h % 12 || 12;
  return h12 + ampm;
}

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function fetchDashboard() {
  loader.start();

  try {
    const r = await fetch(API_BASE + '/api/dashboard');
    const data = await r.json();

    startedAt = data.startedAt * 1000;
    updateAge();

    document.getElementById('searches').textContent = data.searches;
    document.getElementById('publications').textContent = data.publications;
    document.getElementById('embeddings').textContent = data.embeddings ?? '--';

    renderPlatforms(data.platforms);
    renderTiming(data.timing);
    renderTimeline(data.timeline);
    renderPubs(data.topPubs);
    renderTags(data.tags);

    loader.done();
  } catch (e) {
    console.error('failed to fetch dashboard:', e);
    loader.done();
  }
}

let lastN = -1;
async function pollLive() {
  try {
    const r = await fetch(API_BASE + '/activity');
    const c = await r.json();
    const n = c.reduce((a, b) => a + b, 0);
    if (n !== lastN) {
      const el = document.getElementById('live');
      el.innerHTML = n > 0 ? '<span>' + n + '</span> req/6s' : '';
      lastN = n;
    }
  } catch (e) {}
}

// init
fetchDashboard();
setInterval(updateAge, 1000);
pollLive();
setInterval(pollLive, 1000);
