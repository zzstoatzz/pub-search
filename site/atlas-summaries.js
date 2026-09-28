(function(root) {
  'use strict';
  async function validate(data, atlas) {
    if (data?.version !== 2 || data.status !== 'ready' || data.atlasGeneratedAt !== atlas.meta.generatedAt || !Array.isArray(data.clusters)) throw Error('Summaries are updating. Try again shortly.');
    var members = new Map();
    atlas.points.forEach(function(p) {
      if (p.clusterFine < 0) return;
      if (!members.has(p.clusterFine)) members.set(p.clusterFine, []);
      members.get(p.clusterFine).push(p.uri);
    });
    var known = new Map(atlas.clusters.fine.map(function(c) { return [c.id,c]; }));
    var seen = new Set();
    for (var c of data.clusters) {
      var actual = known.get(c.id), uris = members.get(c.id);
      if (!actual || seen.has(c.id) || c.label !== actual.label || c.memberCount !== uris?.length || typeof c.summary !== 'string' || !c.summary.trim() || !Array.isArray(c.sources) || c.sources.length < 3 || !Array.isArray(c.sourceIds) || !c.sourceIds.length) throw Error('Summaries are updating. Try again shortly.');
      seen.add(c.id);
      var hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(uris.slice().sort()))))).map(function(n) { return n.toString(16).padStart(2,'0'); }).join('');
      if (hash !== c.membershipHash) throw Error('Summaries are updating. Try again shortly.');
      var allowed = new Set(uris), sourceIds = new Set();
      for (var s of c.sources) {
        if (!allowed.has(s.uri) || !Number.isInteger(s.id) || sourceIds.has(s.id) || typeof s.title !== 'string' || typeof s.excerpt !== 'string') throw Error('Summary sources could not be verified.');
        sourceIds.add(s.id);
      }
      if (c.sourceIds.some(function(id) { return !sourceIds.has(id); })) throw Error('Summary sources could not be verified.');
    }
    return data.clusters;
  }
  function hitTest(rects,x,y) {
    for (var i=rects.length-1;i>=0;i--) {
      var r=rects[i];
      if (x>=r.x && x<=r.x+r.w && y>=r.y && y<=r.y+r.h) return r.id;
    }
    return null;
  }
  var summaries = new Map(), dataset, loading, panel, status, picker, body, onSelect, onChange;
  var active = null;
  function close() {
    if (!panel) return;
    if (panel.contains(document.activeElement)) document.getElementById('cluster-summary-button').focus({preventScroll:true});
    panel.hidden = true;
    document.getElementById('cluster-summary-button').setAttribute('aria-expanded','false');
  }
  function render(id) {
    var c = summaries.get(id);
    if (!c) return;
    active = id;
    panel.scrollTop = 0;
    picker.value = String(id);
    document.getElementById('cluster-summary-title').textContent = c.label;
    document.getElementById('cluster-summary-text').textContent = c.summary;
    document.getElementById('cluster-summary-coverage').textContent = c.sources.length + ' of ' + c.memberCount.toLocaleString() + ' documents · AI summary';
    var sources = document.getElementById('cluster-summary-sources');
    sources.replaceChildren();
    c.sources.forEach(function(s) {
      var li=document.createElement('li'), link=document.createElement('a');
      link.textContent=s.title || 'Untitled';
      try { var url=new URL(s.url); if (url.protocol==='https:' || url.protocol==='http:') { link.href=url.href; link.target='_blank'; link.rel='noopener noreferrer'; } } catch (_) {}
      li.append(link);
      var details=document.createElement('details'), heading=document.createElement('summary'), excerpt=document.createElement('p');
      heading.textContent='Read excerpt'; excerpt.textContent=s.excerpt;
      details.append(heading,excerpt); li.append(details); sources.append(li);
    });
    document.getElementById('cluster-summary-evidence').open=false;
    status.hidden=true; body.hidden=false; picker.hidden=false;
  }
  async function load() {
    if (!loading) loading=fetch('atlas-summaries.json?build='+encodeURIComponent(dataset.meta.generatedAt),{cache:'no-store'})
      .then(function(r) { if (!r.ok) throw Error('Summaries are unavailable right now.'); return r.json(); })
      .then(function(d) { return validate(d,dataset); })
      .then(function(clusters) {
        summaries=new Map(clusters.map(function(c) { return [c.id,c]; }));
        picker.replaceChildren(...clusters.map(function(c) { return new Option(c.label,String(c.id)); }));
        onChange();
      }).catch(function(error) { loading=null; throw error; });
    return loading;
  }
  async function open(id, focus) {
    if (!panel) return;
    document.getElementById('cluster-summary-button').setAttribute('aria-expanded','true');
    panel.hidden=false; body.hidden=true; picker.hidden=true; status.hidden=false;
    status.textContent='Loading summaries…';
    if (focus) document.getElementById('cluster-summary-close').focus({preventScroll:true});
    try {
      await load();
      if (!summaries.size) throw Error('No summaries yet.');
      var next=summaries.has(id) ? id : (summaries.has(active) ? active : summaries.keys().next().value);
      render(next);
      if (focus) onSelect(next);
    } catch (error) { status.textContent=error.message || 'Summaries are unavailable right now.'; }
  }
  function init(data, select, change) {
    if (!document.getElementById('cluster-summary') || !document.getElementById('cluster-summary-button')) return;
    dataset=data; onSelect=select; onChange=change;
    panel=document.getElementById('cluster-summary'); status=document.getElementById('cluster-summary-status');
    picker=document.getElementById('cluster-summary-picker'); body=document.getElementById('cluster-summary-body');
    document.getElementById('cluster-summary-close').onclick=close;
    document.getElementById('cluster-summary-button').onclick=function() { if(panel.hidden) open(null,true); else close(); };
    picker.onchange=function() { var id=Number(picker.value); render(id); onSelect(id); };
    document.addEventListener('keydown',function(e) { if(e.key==='Escape') close(); });
    setTimeout(function() { load().catch(function() {}); },1500);
    if (new URLSearchParams(location.search).has('topics')) open(null,true);
  }
  root.AtlasSummaries={init:init,open:open,close:close,has:function(id) { return summaries.has(id); },hitTest:hitTest,validate:validate};
})(globalThis);
