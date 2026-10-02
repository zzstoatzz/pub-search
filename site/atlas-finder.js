(function(root) {
  'use strict';
  var names={region:'Regions',topic:'Topics',publication:'Publications',document:'Documents'};
  var glyphs={region:'◎',topic:'◌',publication:'▤',document:'▧'};
  function normalize(s) {
    s = s || '';
    // most titles are plain ASCII, where the unicode passes are identity
    if (!/[^\x00-\x7f]/.test(s)) return s.toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();
    return s.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();
  }
  function rank(title,q) {
    if (!q) return 3;
    if (title===q) return 0;
    if (title.startsWith(q)) return 1;
    return q.split(' ').every(function(w) { return title.includes(w); }) ? 2 : -1;
  }
  function index(data) {
    var regions=new Map(data.clusters.coarse.map(function(c) { return [c.id,c.label]; }));
    var topics=new Map(data.clusters.fine.map(function(c) { return [c.id,c.label]; }));
    var entries=[];
    ['coarse','fine'].forEach(function(level) { data.clusters[level].forEach(function(c) {
      entries.push({kind:level==='fine'?'topic':'region',id:c.id,title:c.label,text:normalize(c.label),count:c.count,parent:c.parent,breadcrumb:level==='fine'?(regions.get(c.parent)||'Atlas'):'Atlas'});
    }); });
    (data.publications||[]).forEach(function(p,i) { entries.push({kind:'publication',id:p.basePath,title:p.name||p.basePath,text:normalize((p.name||'')+' '+p.basePath),exact:normalize(p.name||p.basePath),count:p.count,basePath:p.basePath,breadcrumb:p.basePath}); });
    data.points.forEach(function(p,i) { entries.push({kind:'document',id:i,title:p.title||'Untitled document',raw:p.title,topic:p.clusterFine,region:p.clusterCoarse,basePath:p.basePath,uri:p.uri,breadcrumb:[topics.get(p.clusterFine),p.basePath].filter(Boolean).join(' / ')}); });
    return entries;
  }
  function search(entries,query,scope,kind) {
    var q=normalize(query);
    return entries.filter(function(e) {
      if (kind && e.kind!==kind) return false;
      if (!scope) return q || kind || e.kind==='region' || e.kind==='topic';
      if (scope.kind==='region') return e.kind==='topic' && e.parent===scope.id;
      if (scope.kind==='topic') return e.kind==='document' && e.topic===scope.id;
      return e.kind==='document' && e.basePath===scope.basePath;
    }).map(function(e) {
      // document titles are normalized on the first query that reaches them, not at load
      if (q && e.text===undefined) e.text=normalize(e.raw);
      return {entry:e,rank:rank(e.exact===q?q:e.text,q)};
    })
      .filter(function(r) { return r.rank>=0; })
      .sort(function(a,b) { return a.rank-b.rank || (b.entry.count||0)-(a.entry.count||0) || a.entry.title.localeCompare(b.entry.title); });
  }
  function textUrl(query) {
    var unquoted=query.replace(/"[^"]*"/g,''), match=unquoted.match(/(?:^|\s)@(did:[a-z]+:[A-Za-z0-9._:-]+|[\w.-]+\.\w+)/);
    var author=match&&match[1], q=author?query.replace('@'+author,'').trim():query;
    return '/api/search?mode='+(author&&!q?'keyword':'hybrid')+'&format=v2&limit=30&q='+encodeURIComponent(q)+(author?'&author='+encodeURIComponent(author):'');
  }
  function init(data,onSelect) {
    var entries=null, byUri=null;
    // indexing every title is the largest avoidable cost at load, so it waits for idle time or the first open
    function build() {
      if(entries) return;
      entries=index(data);
      byUri=new Map(entries.filter(function(e) { return e.uri; }).map(function(e) { return [e.uri,e]; }));
    }
    if(window.requestIdleCallback) requestIdleCallback(build,{timeout:8000}); else setTimeout(build,3000);
    var dialog=document.getElementById('atlas-finder'), input=document.getElementById('search-input');
    var results=document.getElementById('finder-results'), status=document.getElementById('finder-status');
    var trail=document.getElementById('finder-trail'), filters=document.getElementById('finder-filters');
    var trigger=document.getElementById('finder-trigger'), remote=document.getElementById('finder-remote');
    var scope=null,scopeStack=[],kind=null,active=-1,buttons=[],timer,request=null,revision=0,displayLimit=40;
    function cancelRequest() { revision++; if(request) request.abort(); request=null; }
    function close() { clearTimeout(timer);timer=null;cancelRequest(); dialog.close(); input.blur(); trigger.focus({preventScroll:true}); }
    function pick(e) { close(); onSelect(e); }
    function browse(e) { cancelRequest(); if(scope)scopeStack.push(scope);scope=e;kind=null;displayLimit=40;input.value='';render();input.focus({preventScroll:true}); }
    function text(tag,value,cls) { var el=document.createElement(tag);el.textContent=value;if(cls)el.className=cls;return el; }
    function row(e,exact) {
      var li=document.createElement('li'),button=document.createElement('button');button.type='button';button.className='finder-result';
      var icon=text('span',glyphs[e.kind],'finder-symbol');icon.dataset.kind=e.kind;icon.setAttribute('aria-hidden','true');
      var copy=text('span','','finder-copy');copy.append(text('strong',e.title),text('small',e.kind.charAt(0).toUpperCase()+e.kind.slice(1)+(e.breadcrumb&&e.breadcrumb!==e.title?' · '+e.breadcrumb:'')));
      var meta=text('span',exact?'Exact name':e.kind==='document'?'Document':(e.count||0).toLocaleString()+' documents','finder-result-meta');
      button.append(icon,copy,meta);button.onclick=function() {pick(e);};button.setAttribute('aria-label','Show '+e.title+' '+e.kind+' on map');
      li.append(button);buttons.push(button);
      if(e.kind!=='document') {var drill=text('button','›','finder-drill');drill.type='button';drill.setAttribute('aria-label','Browse '+e.title);drill.title=e.kind==='region'?'Browse topics':'Browse documents';drill.onclick=function() {browse(e);};li.append(drill);}
      return li;
    }
    function draw(matches,message) {
      results.replaceChildren();buttons=[];active=-1;
      var groups=new Map(),limit=message?matches.length:scope||kind?displayLimit:5;
      matches.forEach(function(m) {var group=m.rank===0?'Exact matches':names[m.entry.kind];if(!groups.has(group))groups.set(group,[]);groups.get(group).push(m);});
      groups.forEach(function(items,name) {
        var section=document.createElement('section'),heading=text('h3',name),list=document.createElement('ul');section.append(heading,list);
        items.slice(0,limit).forEach(function(m) {list.append(row(m.entry,m.rank===0));});
        if(items.length>limit) {
          var more=text('button',scope||kind?'Show more '+name.toLowerCase():'Browse '+items.length.toLocaleString()+' '+name.toLowerCase(),'finder-more');more.onclick=function(){if(scope||kind)displayLimit+=40;else kind=items[0].entry.kind;render();};
          section.append(more);
        }
        results.append(section);
      });
      if(!matches.length) results.append(text('p',message?'No text matches in this Atlas snapshot. Try a different phrase.':input.value?'No matching names in this map. Try fewer words or search document text.':'No items in this view.','finder-empty'));
      status.dataset.state='ready';
      status.textContent=message || (matches.length.toLocaleString()+' matching '+(scope||kind?'items':'places and documents'));
      results.scrollTop=0;
    }
    function render() {
      build();
      clearTimeout(timer);timer=null;
      cancelRequest();trail.replaceChildren();trail.hidden=!scope;
      var home=text('button','Atlas');home.onclick=function(){scope=null;scopeStack=[];kind=null;input.value='';render();input.focus();};trail.append(home);
      scopeStack.forEach(function(parent,i) {var back=text('button',parent.title);back.onclick=function(){scope=parent;scopeStack=scopeStack.slice(0,i);input.value='';render();input.focus({preventScroll:true});};trail.append(text('span','/'),back);});
      if(scope) trail.append(text('span','/'),text('span',scope.title));
      filters.hidden=!!scope;
      filters.querySelectorAll('button').forEach(function(b){b.setAttribute('aria-pressed',String((b.dataset.kind||null)===kind));});
      input.placeholder=scope?'Find in '+scope.title:'Topics, publications, documents';
      remote.hidden=!input.value.trim() || !!scope;
      remote.textContent='Search document text';
      remote.disabled=false;
      draw(search(entries,input.value,scope,kind));
    }
    function fitViewport() {
      var mobile=window.innerWidth<=600,v=window.visualViewport;
      dialog.classList.toggle('finder-compact',mobile&&(v?v.height:window.innerHeight)<520);
      dialog.style.height=mobile&&v?v.height+'px':'';
      dialog.style.maxHeight=mobile&&v?v.height+'px':'';
      dialog.style.top=mobile&&v?v.offsetTop+'px':'';
    }
    if(window.visualViewport) {window.visualViewport.addEventListener('resize',fitViewport);window.visualViewport.addEventListener('scroll',fitViewport);}
    window.addEventListener('resize',fitViewport);
    function open(query) { if(!dialog.open)dialog.showModal();fitViewport();if(query!==undefined)input.value=query;render();input.focus({preventScroll:true}); }
    trigger.disabled=false;trigger.onclick=function(){open();};
    document.getElementById('finder-close').onclick=close;
    dialog.addEventListener('cancel',function(e){e.preventDefault();close();});
    dialog.addEventListener('click',function(e){if(e.target===dialog)close();});
    input.addEventListener('input',function(){cancelRequest();displayLimit=40;clearTimeout(timer);timer=setTimeout(render,80);});
    filters.querySelectorAll('button').forEach(function(b){b.onclick=function(){kind=b.dataset.kind||null;render();};});
    dialog.addEventListener('keydown',function(e) {
      if(e.target!==input && !buttons.includes(e.target))return;
      if(timer && e.target===input && ['ArrowDown','ArrowUp','Enter'].includes(e.key)){clearTimeout(timer);render();}
      if(e.key==='ArrowDown'||e.key==='ArrowUp') {e.preventDefault();if(!buttons.length)return;active=active<0?(e.key==='ArrowDown'?0:buttons.length-1):(active+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;buttons[active].focus({preventScroll:true});buttons[active].scrollIntoView({block:'nearest'});}
      if(e.target!==input && (e.key==='Backspace'||(e.key.length===1&&!e.metaKey&&!e.ctrlKey&&!e.altKey))) {input.focus({preventScroll:true});}
      if(e.key==='Enter'&&e.target===input) {e.preventDefault();if(buttons[0])buttons[0].click();}
    });
    window.addEventListener('keydown',function(e){if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();open();}});
    remote.onclick=function() {
      if(timer)render();
      clearTimeout(timer);timer=null;cancelRequest();var ticket=revision,query=input.value.trim();request=new AbortController();remote.disabled=true;status.dataset.state='loading';status.innerHTML='<pub-loading>Searching document text…</pub-loading>';
      fetch(textUrl(query),{signal:request.signal})
        .then(function(r){if(!r.ok)throw Error('Search unavailable');return r.json();})
        .then(function(d){if(ticket!==revision)return;var matched=(d.results||[]).map(function(r){return byUri.get(r.uri);}).filter(Boolean);draw(matched.map(function(e){return {entry:e,rank:3};}),matched.length+' of '+(d.results||[]).length+' text results in this map');})
        .catch(function(e){if(e.name!=='AbortError'&&ticket===revision){status.dataset.state='error';status.textContent='Text search unavailable. Try again.';}})
        .finally(function(){if(ticket===revision)remote.disabled=false;});
    };
    var q=new URLSearchParams(location.search).get('q');if(q)open(q);
    return {open:open};
  }
  root.AtlasFinder={normalize:normalize,index:index,search:search,textUrl:textUrl,init:init};
})(globalThis);
