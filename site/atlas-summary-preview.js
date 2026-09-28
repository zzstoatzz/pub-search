const byId = (id) => document.getElementById(id);

export function validatePreview(data, atlasHash, atlas) {
  if (data?.version !== 1 || data.atlasSha256 !== atlasHash) throw new Error('These summaries belong to a different Atlas build. Try again after the refresh finishes.');
  if (typeof data.sampling !== 'string' || typeof data.model !== 'string' || !Array.isArray(data.clusters)) throw new Error('The summary preview could not be read.');
  const clusters = new Map(atlas.clusters.fine.map((c) => [c.id, c]));
  const memberships = new Map(atlas.points.map((p) => [p.uri, p.clusterFine]));
  const seen = new Set();
  for (const cluster of data.clusters) {
    const actual = clusters.get(cluster.id);
    if (!actual || cluster.id < 0 || seen.has(cluster.id) || actual.count !== cluster.memberCount || actual.label !== cluster.label || !Array.isArray(cluster.sources) || cluster.sources.length < 3 || !Array.isArray(cluster.sourceIds) || !cluster.sourceIds.length) throw new Error('The summary membership could not be verified.');
    seen.add(cluster.id);
    for (const key of ['summary', 'caveat']) {
      if (typeof cluster[key] !== 'string' || !cluster[key].trim()) throw new Error('The summary text could not be read.');
    }
    if (!['focused', 'mixed'].includes(cluster.coherence)) throw new Error('The summary assessment could not be read.');
    const sourceIds = new Set();
    for (const source of cluster.sources) {
      if (!Number.isInteger(source.id) || sourceIds.has(source.id) || memberships.get(source.uri) !== cluster.id || typeof source.title !== 'string' || typeof source.excerpt !== 'string') throw new Error('The summary sources could not be verified.');
      sourceIds.add(source.id);
    }
    if (cluster.sourceIds.some((id) => !sourceIds.has(id))) throw new Error('A summary reference is missing.');
  }
  return data;
}

function showCluster(data) {
  const cluster = data.clusters.find((item) => String(item.id) === byId('cluster').value);
  if (!cluster) return;
  byId('title').textContent = cluster.label;
  byId('coverage').textContent = `${cluster.sources.length} sampled documents · ${cluster.memberCount.toLocaleString()} cluster members`;
  byId('summary').textContent = cluster.summary;
  byId('coherence').textContent = cluster.coherence === 'mixed' ? 'mixed sample · model assessment' : 'shared subject · model assessment';
  byId('caveat').textContent = cluster.caveat;
  byId('sources').replaceChildren(...cluster.sources.map((source) => {
    const item = document.createElement('li');
    let url;
    try { const parsed = new URL(source.url); if (['https:', 'http:'].includes(parsed.protocol)) url = parsed.href; } catch { /* Some indexed records have no public web URL. */ }
    const title = document.createElement(url ? 'a' : 'span');
    title.className = 'source-title';
    title.textContent = source.title || 'Untitled document';
    if (url) { title.href = url; title.target = '_blank'; title.rel = 'noopener noreferrer'; }
    const excerpt = document.createElement('p');
    excerpt.textContent = source.excerpt.slice(0, 220) + (source.excerpt.length > 220 ? '…' : '');
    item.append(title, excerpt);
    if (cluster.sourceIds.includes(source.id)) {
      const citation = document.createElement('small');
      citation.textContent = 'Cited in this summary';
      item.append(citation);
    }
    if (source.excerpt.length > 220) {
      const details = document.createElement('details');
      const heading = document.createElement('summary');
      heading.textContent = 'Read sampled excerpt';
      const text = document.createElement('p');
      text.className = 'full-excerpt';
      text.textContent = source.excerpt;
      details.append(heading, text);
      item.append(details);
    }
    return item;
  }));
  const url = new URL(location.href);
  url.searchParams.set('cluster', String(cluster.id));
  history.replaceState(null, '', url);
}

async function load() {
  byId('preview').hidden = true;
  byId('retry').hidden = true;
  byId('status').hidden = false;
  byId('status').textContent = 'Loading the latest summaries…';
  try {
    const stamp = Date.now();
    const response = await fetch(`/atlas-summaries.json?preview=${stamp}`, { cache: 'no-store' });
    if (!response.ok) throw new Error('Summaries are not available yet. Atlas is still ready to explore.');
    const data = await response.json();
    if (data.status !== 'ready' || !data.clusters?.length) throw new Error('No summaries are available for this build yet. Atlas is still ready to explore.');
    byId('status').textContent = 'Checking that the summaries match the current Atlas…';
    const atlasResponse = await fetch(`/atlas.json.gz?preview=${stamp}`, { cache: 'no-store' });
    if (!atlasResponse.ok) throw new Error('The current Atlas could not be loaded. Try again.');
    const raw = await new Response(atlasResponse.body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
    const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', raw))].map((n) => n.toString(16).padStart(2, '0')).join('');
    validatePreview(data, hash, JSON.parse(new TextDecoder().decode(raw)));
    byId('cluster').replaceChildren(...data.clusters.map((cluster) => new Option(`${cluster.label} · ${cluster.memberCount.toLocaleString()} documents`, String(cluster.id))));
    const requested = new URL(location.href).searchParams.get('cluster');
    if (data.clusters.some((cluster) => String(cluster.id) === requested)) byId('cluster').value = requested;
    byId('cluster').onchange = () => showCluster(data);
    byId('build').textContent = `${data.clusters.length} cluster previews · Atlas updated ${new Date(data.atlasGeneratedAt).toLocaleString()}`;
    byId('method').textContent = data.sampling;
    byId('model').textContent = `Written by ${data.model}. This preview has not been independently evaluated.`;
    showCluster(data);
    byId('status').hidden = true;
    byId('preview').hidden = false;
  } catch (error) {
    byId('status').textContent = error instanceof Error ? error.message : 'The preview could not load. Try again.';
    byId('retry').hidden = false;
  }
}

if (typeof document !== 'undefined') {
  byId('retry').addEventListener('click', load);
  load();
}
