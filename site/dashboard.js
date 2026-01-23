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

function renderTiming(timing) {
  const el = document.getElementById('timing');
  if (!timing) return;

  const endpoints = ['search', 'similar', 'tags', 'popular'];
  endpoints.forEach(name => {
    const t = timing[name];
    if (!t) return;

    const row = document.createElement('div');
    row.className = 'timing-row';

    if (t.count === 0) {
      row.innerHTML = '<span class="timing-name">' + name + '</span><span class="timing-value dim">--</span>';
    } else {
      row.innerHTML = '<span class="timing-name">' + name + '</span>' +
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

  const endpoints = ['search', 'similar'];
  const colors = { search: '#8b5cf6', similar: '#06b6d4' };

  // check if any endpoint has history data
  const hasData = endpoints.some(name => timing[name]?.history?.some(h => h.count > 0));
  if (!hasData) {
    container.innerHTML = '<div style="color:#444;font-size:11px;text-align:center;padding:2rem">no data yet</div>';
    return;
  }

  const canvas = document.createElement('canvas');
  const chartDiv = document.createElement('div');
  chartDiv.className = 'latency-chart';
  chartDiv.appendChild(canvas);
  container.appendChild(chartDiv);

  const ctx = canvas.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  const rect = chartDiv.getBoundingClientRect();
  canvas.width = rect.width * dpr;
  canvas.height = rect.height * dpr;
  ctx.scale(dpr, dpr);

  const w = rect.width;
  const h = rect.height;
  const padding = { top: 10, right: 10, bottom: 20, left: 10 };
  const chartW = w - padding.left - padding.right;
  const chartH = h - padding.top - padding.bottom;

  // find max value across all endpoints
  let maxVal = 0;
  endpoints.forEach(name => {
    const history = timing[name]?.history || [];
    history.forEach(p => { if (p.avg_ms > maxVal) maxVal = p.avg_ms; });
  });
  if (maxVal === 0) maxVal = 100;

  // draw each endpoint as an area chart
  endpoints.forEach(name => {
    const history = timing[name]?.history || [];
    if (history.length === 0) return;

    const color = colors[name];
    const points = history.map((p, i) => ({
      x: padding.left + (i / (history.length - 1)) * chartW,
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
  });

  // legend
  const legend = document.createElement('div');
  legend.className = 'latency-legend';
  endpoints.forEach(name => {
    const span = document.createElement('span');
    span.innerHTML = '<span class="dot" style="background:' + colors[name] + '"></span>' + name;
    legend.appendChild(span);
  });
  container.appendChild(legend);
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
