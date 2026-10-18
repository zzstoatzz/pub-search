const API_BASE = '/api';

let startedAt = 0;
let lastIndexedAt = 0;

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
  if (d > 0) return d + 'd ' + h + 'h';
  if (h > 0) return h + 'h ' + m + 'm ' + sec + 's';
  return m + 'm ' + sec + 's';
}

function updateAge() {
  if (startedAt > 0) {
    document.getElementById('age').textContent = formatAge(Date.now() - startedAt);
  }
}

// compact "N ago" for the freshness metric
function formatAgo(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return s + 's ago';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  if (h < 24) return h + 'h ago';
  return Math.floor(h / 24) + 'd ago';
}

// "last indexed" is the cheapest is-ingestion-alive signal (turso-sourced).
// recompute on the same 1s tick as uptime so the page feels live; amber past
// 20m of silence — longer than the firehose's natural quiet lulls, so amber
// means ingestion has likely actually stalled.
const FRESHNESS_WARN_MS = 20 * 60 * 1000;
function updateFreshness() {
  if (lastIndexedAt <= 0) return;
  const age = Date.now() - lastIndexedAt;
  const el = document.getElementById('freshness');
  el.textContent = formatAgo(age);
  el.classList.toggle('warn', age > FRESHNESS_WARN_MS);
  document.getElementById('freshness-sub').textContent =
    new Date(lastIndexedAt).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

// each chart's range buttons own the title-of-truth, so we don't duplicate
// "(last X days)" subtitles in markup or carry stale state in JS.

function formatBucketLabel(date, bucket) {
  // dates from the API are YYYY-MM-DD strings (UTC) — parse without timezone shift
  const [y, m, d] = date.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (bucket === 'yearly') {
    return String(y);
  }
  if (bucket === 'monthly') {
    return dt.toLocaleDateString(undefined, { year: 'numeric', month: 'short', timeZone: 'UTC' });
  }
  if (bucket === 'weekly') {
    return 'wk of ' + dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
  }
  return dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
}

function timelinePoints(points, bucket) {
  const sorted = [...points].sort((a, b) => a.date.localeCompare(b.date));
  if (!sorted.length) return sorted;
  const counts = new Map(sorted.map(point => [point.date, point.count]));
  const cursor = new Date(sorted[0].date + 'T00:00:00Z');
  const end = sorted[sorted.length - 1].date;
  const filled = [];
  while (cursor.toISOString().slice(0, 10) <= end) {
    const date = cursor.toISOString().slice(0, 10);
    filled.push({ date, count: counts.get(date) || 0 });
    if (bucket === 'yearly') cursor.setUTCFullYear(cursor.getUTCFullYear() + 1);
    else if (bucket === 'monthly') cursor.setUTCMonth(cursor.getUTCMonth() + 1);
    else cursor.setUTCDate(cursor.getUTCDate() + (bucket === 'weekly' ? 7 : 1));
  }
  return filled;
}

function renderTimeline(timeline, bucket = 'daily') {
  const el = document.getElementById('timeline');
  el.replaceChildren();
  if (!timeline?.length) {
    el.innerHTML = '<p class="timeline-status">No documents in this range.</p>';
    return;
  }
  const points = timelinePoints(timeline, bucket);
  const max = Math.max(...points.map(point => point.count), 1);
  const magnitude = 10 ** Math.floor(Math.log10(max / 4));
  const step = Math.max(1, Math.ceil(max / 4 / magnitude) * magnitude);
  const ceiling = step * 4;
  const unit = { daily: 'day', weekly: 'week', monthly: 'month', yearly: 'year' }[bucket];
  const total = points.reduce((sum, point) => sum + point.count, 0);
  const summary = document.createElement('p');
  summary.className = 'timeline-summary';
  summary.textContent = total.toLocaleString() + ' documents ' + timelineField + ' · per ' + unit + ' · UTC';
  el.appendChild(summary);
  const plot = document.createElement('div');
  plot.className = 'timeline-plot';
  for (let i = 0; i <= 4; i++) {
    const line = document.createElement('div');
    line.className = 'timeline-gridline';
    line.style.bottom = (i * 25) + '%';
    const tick = document.createElement('span');
    tick.className = 'timeline-tick';
    tick.textContent = (step * i).toLocaleString();
    line.appendChild(tick);
    plot.appendChild(line);
  }
  const bars = document.createElement('div');
  bars.className = 'timeline-bars';
  bars.style.gap = 'min(2px, ' + (20 / points.length) + '%)';
  bars.setAttribute('role', 'group');
  bars.setAttribute('aria-label', 'Documents per ' + unit + '. Use left and right arrow keys to explore.');
  const detail = document.createElement('div');
  detail.className = 'timeline-detail';
  detail.setAttribute('aria-live', 'polite');
  detail.setAttribute('aria-atomic', 'true');
  const navigation = document.createElement('div');
  navigation.className = 'timeline-navigation';
  const previous = document.createElement('button');
  const next = document.createElement('button');
  previous.type = next.type = 'button';
  previous.textContent = '←';
  next.textContent = '→';
  previous.setAttribute('aria-label', 'Previous ' + unit);
  next.setAttribute('aria-label', 'Next ' + unit);
  let selected = points.length - 1;
  const select = index => {
    selected = index;
    previous.disabled = index === 0;
    next.disabled = index === points.length - 1;
    [...bars.children].forEach((bar, i) => {
      bar.setAttribute('aria-pressed', String(i === index));
      bar.tabIndex = i === index ? 0 : -1;
    });
    const point = points[index];
    const date = document.createElement('span');
    date.textContent = formatBucketLabel(point.date, bucket);
    const count = document.createElement('strong');
    count.textContent = point.count.toLocaleString() + ' ' + timelineField;
    detail.replaceChildren(date, count);
  };
  points.forEach((point, index) => {
    const bar = document.createElement('button');
    bar.type = 'button';
    bar.className = 'timeline-bar';
    bar.style.setProperty('--height', (point.count / ceiling * 100) + '%');
    bar.setAttribute('aria-label', formatBucketLabel(point.date, bucket) + ': ' + point.count.toLocaleString() + ' documents ' + timelineField);
    bar.appendChild(document.createElement('span'));
    bar.addEventListener('click', () => select(index));
    bar.addEventListener('pointerenter', event => { if (event.pointerType === 'mouse') select(index); });
    bar.addEventListener('focus', () => select(index));
    bars.appendChild(bar);
  });
  bars.addEventListener('keydown', event => {
    let index = selected;
    if (event.key === 'ArrowLeft') index = Math.max(0, selected - 1);
    else if (event.key === 'ArrowRight') index = Math.min(points.length - 1, selected + 1);
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = points.length - 1;
    else return;
    event.preventDefault();
    bars.children[index].focus();
  });
  plot.appendChild(bars);
  el.appendChild(plot);
  const dates = document.createElement('div');
  dates.className = 'timeline-dates';
  for (const point of [points[0], points[points.length - 1]]) {
    const label = document.createElement('span');
    label.textContent = formatBucketLabel(point.date, bucket);
    dates.appendChild(label);
  }
  previous.addEventListener('click', () => select(Math.max(0, selected - 1)));
  next.addEventListener('click', () => select(Math.min(points.length - 1, selected + 1)));
  navigation.append(previous, detail, next);
  el.append(dates, navigation);
  const help = document.createElement('p');
  help.className = 'timeline-help';
  help.textContent = 'Tap or hover to inspect · arrow keys to step';
  el.appendChild(help);
  select(selected);
}

let timelineRange = '30d';
let timelineField = 'indexed';
let timelineRequest = 0;

async function loadTimeline(range, field) {
  if (range) timelineRange = range;
  if (field) timelineField = field;
  const request = ++timelineRequest;
  const el = document.getElementById('timeline');
  el.setAttribute('aria-busy', 'true');
  el.innerHTML = '<p class="timeline-status" role="status">Loading documents…</p>';
  for (const [id, value] of [['timeline-range', timelineRange], ['timeline-field', timelineField]]) {
    document.querySelectorAll('#' + id + ' button').forEach(button => {
      const active = (button.dataset.range || button.dataset.field) === value;
      button.classList.toggle('active', active);
      button.setAttribute('aria-pressed', String(active));
    });
  }
  try {
    const r = await fetch(API_BASE + '/api/timeline?range=' + encodeURIComponent(timelineRange) +
      '&field=' + encodeURIComponent(timelineField));
    if (!r.ok) throw new Error('Timeline request failed: ' + r.status);
    const data = await r.json();
    if (request !== timelineRequest) return;
    renderTimeline(data.points, data.bucket);
  } catch (e) {
    if (request !== timelineRequest) return;
    el.innerHTML = '<div class="timeline-status" role="status">Couldn’t load documents.<button type="button">Try again</button></div>';
    el.querySelector('button').addEventListener('click', () => loadTimeline());
    console.error('failed to load timeline:', e);
  } finally {
    if (request === timelineRequest) el.setAttribute('aria-busy', 'false');
  }
}

async function loadLatency(range) {
  try {
    const r = await fetch(API_BASE + '/api/latency?range=' + encodeURIComponent(range));
    const data = await r.json();
    // server returns { range, hours, endpoints: { search_keyword: [...], ... } }
    // renderLatencyChart expects the same shape it gets in /api/dashboard's
    // `timing` payload — `{ <ep>: { history: [...] } }` — so wrap once.
    const wrapped = {};
    for (const [ep, history] of Object.entries(data.endpoints || {})) {
      wrapped[ep] = { history };
    }
    renderLatencyChart(wrapped);
  } catch (e) {
    console.error('failed to load latency:', e);
  }
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
  // re-renders happen on range-button clicks; clear stale grids first.
  container.innerHTML = '';

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

    // scale the sparkline to the avg series so its trend stays readable;
    // surface the worst single-hour peak as a number (the tail) rather than
    // letting it dominate the y-axis and squash the line flat.
    let maxVal = 0;
    let lastAvg = 0;
    let peakMax = 0;
    history.forEach(p => {
      if (p.avg_ms > maxVal) maxVal = p.avg_ms;
      if (p.max_ms > peakMax) peakMax = p.max_ms;
      if (p.count > 0) lastAvg = p.avg_ms;
    });
    if (maxVal === 0) maxVal = 100;

    const cell = document.createElement('div');
    cell.className = 'latency-cell';

    const friendlyName = ENDPOINT_LABELS[name] || name;
    const label = document.createElement('div');
    label.className = 'latency-cell-label';
    // compact "<avg now> / <peak>" — hover spells out avg vs peak. kept on one
    // line (see .latency-cell-max white-space:nowrap) so it never reflows.
    const numbers = lastAvg > 0
      ? formatMs(lastAvg) + ' <span class="dim">/ ' + formatMs(peakMax) + '</span>'
      : '<span class="dim">/ ' + formatMs(peakMax) + '</span>';
    label.innerHTML = '<span class="dot" style="background:' + color + '"></span>' + friendlyName +
      '<span class="latency-cell-max">' + numbers + '</span>';
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

      const xOf = i => padding.left + (i / Math.max(history.length - 1, 1)) * chartW;
      const yOf = v => padding.top + chartH - (Math.min(v, maxVal) / maxVal) * chartH;

      // filled area under the avg line
      ctx.beginPath();
      ctx.moveTo(xOf(0), padding.top + chartH);
      history.forEach((p, i) => ctx.lineTo(xOf(i), yOf(p.avg_ms)));
      ctx.lineTo(xOf(history.length - 1), padding.top + chartH);
      ctx.closePath();
      ctx.fillStyle = color + '20';
      ctx.fill();

      // avg line
      ctx.beginPath();
      history.forEach((p, i) => {
        const x = xOf(i), y = yOf(p.avg_ms);
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      });
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // hover interaction — show both typical and tail
      canvas.addEventListener('mousemove', e => {
        const canvasRect = canvas.getBoundingClientRect();
        const mouseX = e.clientX - canvasRect.left;
        const idx = Math.round((mouseX - padding.left) / chartW * (history.length - 1));
        const clampedIdx = Math.max(0, Math.min(history.length - 1, idx));
        const point = history[clampedIdx];
        if (point) {
          const time = formatTimestamp(point.hour);
          tooltip.textContent = point.count > 0
            ? time + ' · ' + formatMs(point.avg_ms) + ' avg · ' + formatMs(point.max_ms) + ' peak'
            : time + ' · no traffic';
          tooltip.style.opacity = '1';
        }
      });
      canvas.addEventListener('mouseleave', () => {
        tooltip.style.opacity = '0';
      });
    });
  });
}

// traffic sparkline
let trafficData = [];
let currentRange = '7d';
const RANGE_HOURS = { '24h': 24, '7d': 168, '30d': 720 };

function renderTrafficSparkline(history) {
  if (!history) return;
  trafficData = history;
  drawTrafficSvg();
}

function drawTrafficSvg() {
  const container = document.getElementById('traffic-sparkline');
  if (!container) return;
  container.innerHTML = '';

  const hours = RANGE_HOURS[currentRange] || 168;
  const sliced = trafficData.slice(-hours);
  // trim leading zeros — only draw from first non-zero point
  let firstNonZero = sliced.findIndex(d => d.count > 0);
  if (firstNonZero === -1) return; // nothing to draw
  // include one zero point before the first non-zero for context
  if (firstNonZero > 0) firstNonZero--;
  const data = sliced.slice(firstNonZero);
  if (data.length === 0) return;

  const max = Math.max(...data.map(d => d.count), 1);
  const w = container.clientWidth || 560;
  const h = 60;

  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('width', w);
  svg.setAttribute('height', h);
  svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
  svg.style.display = 'block';

  const pad = { top: 2, right: 2, bottom: 2, left: 2 };
  const cw = w - pad.left - pad.right;
  const ch = h - pad.top - pad.bottom;

  const points = data.map((d, i) => {
    const x = pad.left + (i / Math.max(data.length - 1, 1)) * cw;
    const y = pad.top + ch - (d.count / max) * ch;
    return { x, y, d };
  });

  // filled area
  const polyPoints = [pad.left + ',' + (pad.top + ch)]
    .concat(points.map(p => p.x + ',' + p.y))
    .concat([(pad.left + cw) + ',' + (pad.top + ch)]);
  const polygon = document.createElementNS(ns, 'polygon');
  polygon.setAttribute('points', polyPoints.join(' '));
  polygon.setAttribute('fill', '#1B7340');
  polygon.setAttribute('opacity', '0.15');
  svg.appendChild(polygon);

  // line
  const linePoints = points.map(p => p.x + ',' + p.y).join(' ');
  const polyline = document.createElementNS(ns, 'polyline');
  polyline.setAttribute('points', linePoints);
  polyline.setAttribute('fill', 'none');
  polyline.setAttribute('stroke', '#1B7340');
  polyline.setAttribute('stroke-width', '1.5');
  svg.appendChild(polyline);

  // hover overlay
  const overlay = document.createElementNS(ns, 'rect');
  overlay.setAttribute('width', w);
  overlay.setAttribute('height', h);
  overlay.setAttribute('fill', 'transparent');
  svg.appendChild(overlay);

  container.appendChild(svg);

  // tooltip
  const tooltip = document.createElement('div');
  tooltip.className = 'traffic-tooltip';
  container.appendChild(tooltip);

  svg.addEventListener('mousemove', function(e) {
    const rect = svg.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const idx = Math.round((mouseX - pad.left) / cw * (data.length - 1));
    const ci = Math.max(0, Math.min(data.length - 1, idx));
    const pt = data[ci];
    if (pt) {
      const d = new Date(pt.hour * 1000);
      const label = d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) + ' ' + formatTimestamp(pt.hour);
      tooltip.textContent = label + ' · ' + pt.count + ' req';
      tooltip.style.opacity = '1';
    }
  });
  svg.addEventListener('mouseleave', function() {
    tooltip.style.opacity = '0';
  });
}

// range button handler
document.getElementById('traffic-range')?.addEventListener('click', function(e) {
  const btn = e.target.closest('button[data-range]');
  if (!btn) return;
  currentRange = btn.dataset.range;
  this.querySelectorAll('button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  drawTrafficSvg();
});

document.getElementById('timeline-range')?.addEventListener('click', function(e) {
  const btn = e.target.closest('button[data-range]');
  if (!btn) return;
  this.querySelectorAll('button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  loadTimeline(btn.dataset.range, null);
});

document.getElementById('timeline-field')?.addEventListener('click', function(e) {
  const btn = e.target.closest('button[data-field]');
  if (!btn) return;
  this.querySelectorAll('button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  loadTimeline(null, btn.dataset.field);
});

document.getElementById('latency-range')?.addEventListener('click', function(e) {
  const btn = e.target.closest('button[data-range]');
  if (!btn) return;
  this.querySelectorAll('button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  loadLatency(btn.dataset.range);
});

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

    document.getElementById('searches').textContent = data.searches.toLocaleString();
    document.getElementById('publications').textContent = data.publications.toLocaleString();
    document.getElementById('embeddings').textContent = data.embeddings?.toLocaleString() ?? '--';

    // embedding coverage + backlog, derived from the counts we already have.
    // backlog = docs the embedder hasn't reached yet; coverage is the headline.
    if (typeof data.embeddings === 'number' && data.documents > 0) {
      const pending = Math.max(0, data.documents - data.embeddings);
      const pct = (data.embeddings / data.documents) * 100;
      const sub = document.getElementById('embeddings-sub');
      sub.textContent = pct.toFixed(1) + '% covered' +
        (pending > 0 ? ' · ' + pending.toLocaleString() + ' pending' : '');
    }

    // freshness: last-indexed time drives a live "N ago" readout
    lastIndexedAt = (data.lastIndexedAt || 0) * 1000;
    updateFreshness();


    if (data.relayUrl) {
      const relayEl = document.getElementById('relay');
      try {
        const host = new URL(data.relayUrl).hostname;
        relayEl.textContent = host;
        relayEl.title = data.relayUrl;
      } catch {
        relayEl.textContent = data.relayUrl;
      }
    }

    renderPlatforms(data.platforms);
    renderTiming(data.timing);
    renderTrafficSparkline(data.trafficHistory);

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

new ResizeObserver(drawTrafficSvg).observe(document.getElementById('traffic-sparkline'));

// init
fetchDashboard();
loadTimeline();
setInterval(updateAge, 1000);
setInterval(updateFreshness, 1000);
pollLive();
setInterval(pollLive, 1000);
