(function(root) {
  'use strict';
  async function validate(data, atlas) {
    if (data?.version !== 2 || data.status !== 'ready' || data.atlasGeneratedAt !== atlas.meta.generatedAt || !Array.isArray(data.clusters)) throw Error('Summaries are updating. Try again shortly.');
    var result = [];
    for (var level of ['fine','coarse']) {
      var entries=level==='fine' ? data.clusters : (data.regions === undefined ? [] : data.regions);
      if (!Array.isArray(entries)) throw Error('Summaries are updating. Try again shortly.');
      var members = new Map(), field=level==='fine'?'clusterFine':'clusterCoarse';
      atlas.points.forEach(function(p) {
        if (p[field] < 0) return;
        if (!members.has(p[field])) members.set(p[field], []);
        members.get(p[field]).push(p.uri);
      });
      var known = new Map((atlas.clusters[level] || []).map(function(c) { return [c.id,c]; }));
      var seen = new Set();
      for (var c of entries) {
        var actual = known.get(c.id), uris = members.get(c.id);
        if (!actual || seen.has(c.id) || c.label !== actual.label || c.memberCount !== uris?.length || typeof c.summary !== 'string' || !c.summary.trim() || !Array.isArray(c.sources) || c.sources.length < 3 || !Array.isArray(c.sourceIds) || !c.sourceIds.length) throw Error('Summaries are updating. Try again shortly.');
        seen.add(c.id);
        var hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(uris.slice().sort()))))).map(function(n) { return n.toString(16).padStart(2,'0'); }).join('');
        if (hash !== c.membershipHash) throw Error('Summaries are updating. Try again shortly.');
        var allowed = new Set(uris), sourceIds = new Set();
        for (var source of c.sources) {
          if (!allowed.has(source.uri) || !Number.isInteger(source.id) || sourceIds.has(source.id) || typeof source.title !== 'string' || typeof source.excerpt !== 'string') throw Error('Summary sources could not be verified.');
          sourceIds.add(source.id);
        }
        if (c.sourceIds.some(function(id) { return !sourceIds.has(id); })) throw Error('Summary sources could not be verified.');
        result.push(Object.assign({}, c, {level:level}));
      }
    }
    return result;
  }
  function hitTest(rects,x,y) {
    var best=null, distance=Infinity;
    for (var r of rects) {
      if (x<r.x || x>r.x+r.w || y<r.y || y>r.y+r.h) continue;
      var d=Math.abs(y-(r.y+r.h/2));
      if (d<distance) { distance=d; best=r.id; }
    }
    return best;
  }
  function nearby(points, bounds, level, platforms) {
    var counts = new Map(), field = level === 'coarse' ? 'clusterCoarse' : 'clusterFine';
    points.forEach(function(p) {
      if (p[field] < 0 || p.x < bounds.left || p.x > bounds.right || p.y < bounds.top || p.y > bounds.bottom || (platforms && !platforms.has(p.platform))) return;
      counts.set(p[field], (counts.get(p[field]) || 0) + 1);
    });
    return Array.from(counts, function(pair) { return {id:pair[0],count:pair[1],level:level}; }).sort(function(a,b) { return b.count-a.count || a.id-b.id; });
  }
  var summaries = new Map(), dataset, loading, panel, status, body, button, list, listView;
  var onSelect, onDocument, toUrl, active=null, topics=new Map(), members=new Map(), visible=[], listLimit=20, documentLimit=20;
  var viewKey='', viewTimer, loadError='', loaded=false;
  function key(id,level) { return (level || 'fine')+':'+id; }
  function setOpen(value) {
    panel.hidden=!value;
    button.setAttribute('aria-expanded',String(value));
  }
  function close() {
    if (!panel) return;
    if (panel.contains(document.activeElement)) button.focus({preventScroll:true});
    setOpen(false); active=null; onSelect(null);
  }
  function safeLink(link,url) {
    try { var parsed=new URL(url); if (parsed.protocol==='https:' || parsed.protocol==='http:') { link.href=parsed.href; link.target='_blank'; link.rel='noopener noreferrer'; } } catch (_) {}
  }
  function renderSummary() {
    if (!active) return;
    var c=summaries.get(key(active.id,active.level));
    var text=document.getElementById('cluster-summary-text'), evidence=document.getElementById('cluster-summary-evidence');
    text.hidden=!c; evidence.hidden=!c;
    status.hidden=!!c;
    status.textContent=loadError || (loaded ? 'Summary unavailable.' : 'Loading summary…');
    if (!c) return;
    text.textContent=c.summary;
    document.getElementById('cluster-summary-coverage').textContent=c.sources.length+' of '+c.memberCount.toLocaleString()+' documents · AI summary';
    var sources=document.getElementById('cluster-summary-sources'); sources.replaceChildren();
    c.sources.forEach(function(s) {
      var li=document.createElement('li'), link=document.createElement('a'); link.textContent=s.title || 'Untitled'; safeLink(link,s.url); li.append(link);
      var details=document.createElement('details'), heading=document.createElement('summary'), excerpt=document.createElement('p');
      heading.textContent='Read excerpt'; excerpt.textContent=s.excerpt; details.append(heading,excerpt); li.append(details); sources.append(li);
    });
  }
  function renderDocuments() {
    var items=members.get(key(active.id,active.level)) || [], target=document.getElementById('cluster-documents'); target.replaceChildren();
    document.getElementById('cluster-document-count').textContent=items.length.toLocaleString()+' documents';
    items.slice(0,documentLimit).forEach(function(index) {
      var p=dataset.points[index], li=document.createElement('li'), link=document.createElement('a'), locate=document.createElement('button');
      link.textContent=p.title || 'Untitled'; safeLink(link,toUrl(p)); li.append(link);
      locate.textContent='show on map'; locate.setAttribute('aria-label','Show '+(p.title || 'document')+' on map'); locate.onclick=function() { close(); onDocument(index); }; li.append(locate); target.append(li);
    });
    document.getElementById('cluster-documents-more').hidden=items.length<=documentLimit;
  }
  function markSummaries() {
    list.querySelectorAll('small[data-topic-id]').forEach(function(meta) {
      meta.textContent=meta.dataset.countLabel+(summaries.has(key(Number(meta.dataset.topicId),meta.dataset.level)) ? ' · summary' : '');
    });
  }
  function renderList() {
    list.replaceChildren();
    document.getElementById('cluster-nearby-empty').hidden=visible.length>0;
    visible.slice(0,listLimit).forEach(function(item) {
      var c=topics.get(key(item.id,item.level)); if (!c) return;
      var li=document.createElement('li'), pick=document.createElement('button'), label=document.createElement('span'), meta=document.createElement('small');
      label.textContent=c.label; meta.textContent=item.count.toLocaleString()+' in view · '+(members.get(key(item.id,item.level)) || []).length.toLocaleString()+' total';
      meta.dataset.topicId=item.id; meta.dataset.level=item.level; meta.dataset.countLabel=meta.textContent;
      pick.append(label,meta); pick.onclick=function() { open(item.id,true,item.level); }; li.append(pick); list.append(li);
    });
    document.getElementById('cluster-nearby-more').hidden=visible.length<=listLimit;
    button.textContent='topics in view · '+visible.length; markSummaries();
  }
  function browse() {
    active=null; onSelect(null); setOpen(true); listView.hidden=false; body.hidden=true; status.hidden=true;
    document.getElementById('cluster-summary-back').hidden=true;
    panel.scrollTop=0; renderList(); document.getElementById('cluster-summary-close').focus({preventScroll:true});
  }
  function open(id,focus,level) {
    level=level || 'fine';
    var c=topics.get(key(id,level)); if (!panel || !c) return;
    active={id:id,level:level}; documentLimit=20; setOpen(true); listView.hidden=true; body.hidden=false;
    document.getElementById('cluster-summary-back').hidden=false;
    document.getElementById('cluster-summary-title').textContent=c.label;
    document.getElementById('cluster-summary-evidence').open=false;
    renderSummary(); renderDocuments(); panel.scrollTop=0; document.getElementById('cluster-summary-back').focus({preventScroll:true});
    onSelect(active,focus,members.get(key(id,level)) || []);
    load().then(renderSummary).catch(function() { renderSummary(); });
  }
  function load() {
    if (loading) return loading;
    loading=fetch('atlas-summaries.json?build='+encodeURIComponent(dataset.meta.generatedAt),{cache:'no-store'})
      .then(function(r) { if (!r.ok) throw Error('Summary unavailable. You can still browse the documents.'); return r.json(); })
      .then(function(d) { return validate(d,dataset); })
      .then(function(clusters) { summaries=new Map(clusters.map(function(c) { return [key(c.id,c.level),c]; })); loaded=true; loadError=''; markSummaries(); })
      .catch(function(error) { loadError=error.message; loading=null; throw error; });
    return loading;
  }
  function updateView(bounds,level,platforms) {
    if (!dataset) return;
    var next=JSON.stringify([bounds,level,platforms ? Array.from(platforms).sort() : null]);
    if(next===viewKey) return;
    viewKey=next; clearTimeout(viewTimer);
    viewTimer=setTimeout(function() {
      visible=nearby(dataset.points,bounds,level,platforms); listLimit=20;
      if (!active) renderList(); else button.textContent='topics in view · '+visible.length;
    },180);
  }
  function init(data, select, documentSelect, url) {
    panel=document.getElementById('cluster-summary'); button=document.getElementById('cluster-summary-button');
    if (!panel || !button || !document.getElementById('cluster-nearby')) return;
    dataset=data; onSelect=select; onDocument=documentSelect; toUrl=url;
    status=document.getElementById('cluster-summary-status'); body=document.getElementById('cluster-summary-body');
    list=document.getElementById('cluster-nearby'); listView=document.getElementById('cluster-nearby-view');
    ['fine','coarse'].forEach(function(level) {
      data.clusters[level].forEach(function(c) { topics.set(key(c.id,level),c); members.set(key(c.id,level),[]); });
      data.points.forEach(function(p,i) { var group=members.get(key(level==='fine'?p.clusterFine:p.clusterCoarse,level)); if(group) group.push(i); });
    });
    document.getElementById('cluster-summary-close').onclick=close;
    document.getElementById('cluster-summary-back').onclick=browse;
    document.getElementById('cluster-nearby-more').onclick=function() { listLimit+=20; renderList(); };
    document.getElementById('cluster-documents-more').onclick=function() { documentLimit+=20; renderDocuments(); };
    button.onclick=function() { if(panel.hidden) browse(); else close(); };
    document.addEventListener('keydown',function(e) { if(e.key==='Escape' && !panel.hidden) close(); });
    setTimeout(function() { load().then(renderSummary).catch(function() {}); },1500);
    if (new URLSearchParams(location.search).has('topics')) browse();
  }
  root.AtlasSummaries={init:init,open:open,close:close,updateView:updateView,nearby:nearby,hitTest:hitTest,validate:validate};
})(globalThis);
