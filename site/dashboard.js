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
    row.innerHTML = '<span class="pub-name">' + escapeHtml(p.name) + '</span><span class="pub-count">' + p.count + '</span>';
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
