(function(root) {
  'use strict';
  // lite: the summaries-only sidecar, whose entries carry source counts in place of the excerpts
  async function validate(data, atlas, lite) {
    if (data?.version !== 2 || !Array.isArray(data.clusters)) throw Error('Summary data could not be verified.');
    if (data.status !== 'ready') throw Error('Summaries were not generated for this map.');
    if (data.atlasGeneratedAt !== atlas.meta.generatedAt) throw Object.assign(Error('The map and summaries are out of sync. Reload to refresh them.'), {code:'stale'});
    var result = [];
    for (var level of ['fine','coarse']) {
      var entries=level==='fine' ? data.clusters : (data.regions === undefined ? [] : data.regions);
      if (!Array.isArray(entries)) throw Error('Summary data could not be verified.');
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
        if (!actual || seen.has(c.id) || c.label !== actual.label || c.memberCount !== uris?.length || typeof c.summary !== 'string' || !c.summary.trim() || (lite ? !Number.isInteger(c.memberSourceCount) || c.memberSourceCount < 3 || !Number.isInteger(c.contextSourceCount) || c.contextSourceCount < 0 : !Array.isArray(c.sources) || c.sources.length < 3) || !Array.isArray(c.sourceIds) || !c.sourceIds.length) throw Error('Summary data could not be verified.');
        seen.add(c.id);
        var hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(uris.slice().sort()))))).map(function(n) { return n.toString(16).padStart(2,'0'); }).join('');
        if (hash !== c.membershipHash) throw Error('Summary data could not be verified.');
        if (lite) { result.push(Object.assign({}, c, {level:level})); continue; }
        var allowed = new Set(uris), sourceIds = new Set(), memberIds = new Set();
        for (var source of c.sources) {
          var isContext=source.role==='context';
          if (!Number.isInteger(source.id) || source.id<1 || sourceIds.has(source.id) || typeof source.title !== 'string' || typeof source.excerpt !== 'string') throw Error('Summary sources could not be verified.');
          if (isContext) {
            if (allowed.has(source.uri) || typeof source.uri!=='string' || !source.uri.startsWith('at://') || !Number.isFinite(source.cosineSimilarity) || source.cosineSimilarity<0.75 || source.cosineSimilarity>1) throw Error('Related sources could not be verified.');
          } else if (!allowed.has(source.uri) || (source.role!==undefined && source.role!=='member')) {
            throw Error('Summary sources could not be verified.');
          }
          sourceIds.add(source.id);
          if (!isContext) memberIds.add(source.id);
        }
        if (memberIds.size<3 || !c.sourceIds.some(function(id) { return memberIds.has(id); }) || c.sourceIds.some(function(id) { return !sourceIds.has(id); })) throw Error('Summary sources could not be verified.');
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
  var viewKey='', viewTimer, loadError=null, loaded=false, sourcesLoading=null, sourcesError=false;
  var LOCATE_ICON='<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><circle cx="8" cy="8" r="4"/><path d="M8 1v3M8 12v3M1 8h3M12 8h3"/></svg>';
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
    status.textContent=loadError?.message || (loaded ? 'No summary is available for this topic. You can still browse its documents.' : 'Loading summary…');
    if(!c && !loaded && !loadError) status.innerHTML='<pub-loading>Loading summary…</pub-loading>';
    var retry=document.getElementById('cluster-summary-retry');
    retry.hidden=!!c || (!loaded && !loadError);
    retry.textContent=loadError?.code==='stale' ? 'Reload map' : 'Retry summary';
    if (!c) return;
    text.textContent=c.summary;
    var contextCount=c.sources ? c.sources.filter(function(s) { return s.role==='context'; }).length : c.contextSourceCount;
    document.getElementById('cluster-summary-coverage').textContent=(c.sources ? c.sources.length-contextCount : c.memberSourceCount)+' of '+c.memberCount.toLocaleString()+' documents'+(contextCount ? ' · '+contextCount+' related source'+(contextCount===1 ? '' : 's') : '')+' · AI summary';
    var sources=document.getElementById('cluster-summary-sources'); sources.replaceChildren();
    if (!c.sources) {
      if (!evidence.open) return;
      var note=document.createElement('li');
      if (sourcesError) note.textContent='Sources could not be loaded. Close and reopen to try again.';
      else { note.innerHTML='<pub-loading>Gathering sources…</pub-loading>'; loadSources(); }
      sources.append(note); return;
    }
    c.sources.forEach(function(s) {
      var li=document.createElement('li'), link=document.createElement('a'); link.textContent=(s.role==='context' ? 'Related context: ' : '')+(s.title || 'Untitled'); safeLink(link,s.url); li.append(link);
      var details=document.createElement('details'), heading=document.createElement('summary'), excerpt=document.createElement('p');
      heading.textContent='Read excerpt'; excerpt.textContent=s.excerpt; details.append(heading,excerpt); li.append(details); sources.append(li);
    });
  }
  // uri -> thumbnail url, '' when the document has no cover or the lookup failed
  var coverUrls=new Map();
  function parseCovers(body) {
    var found=new Map();
    if (!body || !Array.isArray(body.documents)) return found;
    body.documents.forEach(function(doc) {
      if (typeof doc?.uri!=='string' || typeof doc.did!=='string' || typeof doc.coverImage!=='string' || !doc.coverImage) return;
      found.set(doc.uri,'https://cdn.bsky.app/img/feed_thumbnail/plain/'+encodeURIComponent(doc.did)+'/'+encodeURIComponent(doc.coverImage)+'@jpeg');
    });
    return found;
  }
  function covers(uris) {
    var wanted=uris.filter(function(uri) { return !coverUrls.has(uri); }), requests=[];
    wanted.forEach(function(uri) { coverUrls.set(uri,''); });
    // /api/document takes at most 25 uris per request
    for (var i=0;i<wanted.length;i+=25) requests.push(fetch('/api/document?content=false&uri='+encodeURIComponent(wanted.slice(i,i+25).join(',')))
      .then(function(r) { return r.ok ? r.json() : null; })
      .then(function(body) { parseCovers(body).forEach(function(url,uri) { coverUrls.set(uri,url); }); })
      .catch(function() {}));
    return Promise.all(requests).then(function() { return coverUrls; });
  }
  function showCovers(target) {
    target.querySelectorAll('li[data-uri]').forEach(function(li) {
      var url=coverUrls.get(li.dataset.uri);
      if (!url || li.querySelector('img')) return;
      var img=document.createElement('img'); img.alt=''; img.loading='lazy'; img.onerror=function() { img.remove(); }; img.src=url;
      li.insertBefore(img,li.lastChild);
    });
  }
  function renderDocuments() {
    var items=members.get(key(active.id,active.level)) || [], target=document.getElementById('cluster-documents'); target.replaceChildren();
    document.getElementById('cluster-document-count').textContent=items.length.toLocaleString()+' documents';
    items.slice(0,documentLimit).forEach(function(index) {
      var p=dataset.points[index], li=document.createElement('li'), link=document.createElement('a'), locate=document.createElement('button');
      link.textContent=p.title || 'Untitled'; safeLink(link,toUrl(p)); li.dataset.uri=p.uri; li.append(link);
      locate.innerHTML=LOCATE_ICON; locate.title='Show on map'; locate.setAttribute('aria-label','Show '+(p.title || 'document')+' on map'); locate.onclick=function() { close(); onDocument(index); }; li.append(locate); target.append(li);
    });
    document.getElementById('cluster-documents-more').hidden=items.length<=documentLimit;
    showCovers(target);
    covers(items.slice(0,documentLimit).map(function(index) { return dataset.points[index].uri; })).then(function() { showCovers(target); });
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
    document.getElementById('cluster-summary-back').hidden=true; document.getElementById('cluster-summary-heading').hidden=false;
    document.getElementById('cluster-summary-retry').hidden=true;
    panel.scrollTop=0; renderList(); panel.focus({preventScroll:true});
  }
  function open(id,focus,level) {
    level=level || 'fine';
    var c=topics.get(key(id,level)); if (!panel || !c) return;
    active={id:id,level:level}; documentLimit=20; setOpen(true); listView.hidden=true; body.hidden=false;
    document.getElementById('cluster-summary-back').hidden=false; document.getElementById('cluster-summary-heading').hidden=true;
    document.getElementById('cluster-summary-title').textContent=c.label;
    document.getElementById('cluster-summary-evidence').open=false;
    renderSummary(); renderDocuments(); panel.scrollTop=0; panel.focus({preventScroll:true});
    onSelect(active,focus,members.get(key(id,level)) || []);
    load().then(renderSummary).catch(function() { renderSummary(); });
  }
  function fetchSidecar(name) {
    return fetch(name+'?build='+encodeURIComponent(dataset.meta.generatedAt))
      .then(function(r) { if (!r.ok) throw Error('Summaries could not be loaded. You can still browse the documents.'); return r.json(); });
  }
  function loadSources() {
    if (sourcesLoading) return;
    sourcesLoading=fetchSidecar('atlas-summaries.json').then(function(d) { return validate(d,dataset); })
      .then(function(clusters) { clusters.forEach(function(c) { summaries.set(key(c.id,c.level),c); }); })
      .catch(function() { sourcesError=true; sourcesLoading=null; })
      .then(renderSummary);
  }
  function load() {
    if (loading) return loading;
    if (loaded) return Promise.resolve();
    loadError=null;
    renderSummary();
    // the full sidecar is mostly source excerpts; summaries come from the
    // small one, and a deploy that predates it falls back to the full file
    loading=fetchSidecar('atlas-summaries-lite.json').then(function(d) { return validate(d,dataset,true); })
      .catch(function() { return fetchSidecar('atlas-summaries.json').then(function(d) { return validate(d,dataset); }); })
      .then(function(clusters) { summaries=new Map(clusters.map(function(c) { return [key(c.id,c.level),c]; })); loaded=true; loadError=null; markSummaries(); })
      .catch(function(error) { loadError=error instanceof TypeError || error instanceof SyntaxError ? Error('Summaries could not be loaded. You can still browse the documents.') : error; loading=null; renderSummary(); throw error; });
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
    // focus lands on the panel, not a button, so opening it by pointer does not draw a focus ring on a control
    panel.tabIndex=-1;
    status=document.getElementById('cluster-summary-status'); body=document.getElementById('cluster-summary-body');
    list=document.getElementById('cluster-nearby'); listView=document.getElementById('cluster-nearby-view');
    ['fine','coarse'].forEach(function(level) {
      data.clusters[level].forEach(function(c) { topics.set(key(c.id,level),c); members.set(key(c.id,level),[]); });
      data.points.forEach(function(p,i) { var group=members.get(key(level==='fine'?p.clusterFine:p.clusterCoarse,level)); if(group) group.push(i); });
    });
    document.getElementById('cluster-summary-close').onclick=close;
    document.getElementById('cluster-summary-retry').onclick=function() {
      if (loadError?.code==='stale') { location.reload(); return; }
      if (loading && !loaded) return;
      loaded=false; loading=null; sourcesLoading=null; sourcesError=false;
      load().then(renderSummary).catch(function() {});
    };
    document.getElementById('cluster-summary-back').onclick=browse;
    document.getElementById('cluster-summary-evidence').addEventListener('toggle',function(e) { if (e.target.open) { sourcesError=false; renderSummary(); } });
    document.getElementById('cluster-nearby-more').onclick=function() { listLimit+=20; renderList(); };
    document.getElementById('cluster-documents-more').onclick=function() { documentLimit+=20; renderDocuments(); };
    button.onclick=function() { if(panel.hidden) browse(); else close(); };
    document.addEventListener('keydown',function(e) { if(e.key==='Escape' && !panel.hidden) close(); });
    load().then(renderSummary).catch(function() {});
    if (new URLSearchParams(location.search).has('topics')) browse();
  }
  root.AtlasSummaries={init:init,open:open,close:close,updateView:updateView,nearby:nearby,hitTest:hitTest,validate:validate,covers:covers,parseCovers:parseCovers};
})(globalThis);
