import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import '../../site/atlas-summaries.js';
const {validate, hitTest} = globalThis.AtlasSummaries;
const atlas = {meta:{generatedAt:'today'},clusters:{fine:[{id:7,label:'agents'}]},points:[1,2,3].map(i=>({uri:`at://did:plc:a/site.standard.document/${i}`,clusterFine:7}))};
const data = {version:2,status:'ready',atlasGeneratedAt:'today',clusters:[{id:7,label:'agents',memberCount:3,membershipHash:createHash('sha256').update(JSON.stringify(atlas.points.map(p=>p.uri).sort())).digest('hex'),summary:'Software agents coordinate tasks.',sourceIds:[1],sources:atlas.points.map((p,i)=>({id:i+1,uri:p.uri,title:'Document',excerpt:'Content'}))}]};
test('accepts summaries tied to exact memberships',async()=>assert.deepEqual(await validate(data,atlas),data.clusters.map(c=>({...c,level:'fine'}))));
test('rejects stale build, counts, labels and evidence',async()=>{
  for(const field of ['atlasGeneratedAt','memberCount','label','sourceIds','membershipHash']) {
    const changed=structuredClone(data);
    if(field==='atlasGeneratedAt') changed[field]='yesterday';
    else changed.clusters[0][field]=field==='sourceIds'?[4]:field==='memberCount'?4:'changed';
    await assert.rejects(validate(changed,atlas));
  }
});
test('unassigned and other-cluster documents cannot support a summary',async()=>{
  for(const clusterFine of [-1,8]) {
    const changed=structuredClone(atlas); changed.points[0].clusterFine=clusterFine;
    await assert.rejects(validate(data,changed));
  }
});
test('only visible label bounds activate a summary',()=>{
  const rects=[{id:7,x:10,y:20,w:80,h:44}];
  assert.equal(hitTest(rects,30,40),7);
  assert.equal(hitTest(rects,9,40),null);
  assert.equal(hitTest([],30,40),null);
});

test('new Atlas assets bypass legacy caches and match the new offline manifest', async () => {
  const {readFile} = await import('node:fs/promises');
  const {createRequire} = await import('node:module');
  const config = createRequire(import.meta.url)('../../site/workbox-config.cjs');
  const html = await readFile(new URL('../../site/atlas.html', import.meta.url), 'utf8');
  const files = ['atlas.css','atlas.js','atlas-summaries.js'];
  const {manifest} = await config.manifestTransforms[0](files.map(url=>({url,revision:'content-hash'})));
  for (const file of files) {
    const reference = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map(m=>m[1]).find(url=>url.startsWith(file+'?'));
    assert.ok(reference, `${file} must bypass the previous worker's unversioned cache`);
    const url = new URL(reference,'https://example.com');
    for (const key of [...url.searchParams.keys()]) if (/^v$/.test(key)) url.searchParams.delete(key);
    assert.notEqual(url.search,'');
    assert.ok(manifest.some(entry=>entry.url===reference), `${file} must remain available offline`);
  }
});

test('nearby topics count actual visible members, excluding unassigned and filtered documents', () => {
  const points=[
    {x:0,y:0,clusterFine:7,clusterCoarse:2,platform:'leaflet'},
    {x:0.5,y:0.5,clusterFine:7,clusterCoarse:3,platform:'other'},
    {x:0,y:0,clusterFine:-1,clusterCoarse:-1,platform:'leaflet'},
    {x:5,y:5,clusterFine:8,clusterCoarse:2,platform:'leaflet'},
  ];
  const bounds={left:-1,right:1,top:-1,bottom:1};
  assert.deepEqual(globalThis.AtlasSummaries.nearby(points,bounds,'fine',null),[{id:7,count:2,level:'fine'}]);
  assert.deepEqual(globalThis.AtlasSummaries.nearby(points,bounds,'fine',new Set(['leaflet'])),[{id:7,count:1,level:'fine'}]);
  assert.deepEqual(globalThis.AtlasSummaries.nearby(points,bounds,'coarse',null),[{id:2,count:1,level:'coarse'},{id:3,count:1,level:'coarse'}]);
  assert.deepEqual(globalThis.AtlasSummaries.nearby(points,{left:9,right:10,top:9,bottom:10},'fine',null),[]);
});

test('overlapping touch padding selects the closer label',()=>{
  assert.equal(hitTest([{id:1,x:0,y:20,w:100,h:44},{id:2,x:0,y:50,w:100,h:44}],40,53),1);
});


test('regions use their own membership even when a fine cluster has the same id', async()=>{
  const map=structuredClone(atlas), sidecar=structuredClone(data);
  map.clusters.coarse=[{id:7,label:'product development'}];
  map.points.forEach(p=>p.clusterCoarse=-1);
  const regionPoints=[4,5,6].map(i=>({uri:`at://did:plc:b/site.standard.document/${i}`,clusterCoarse:7,clusterFine:-1}));
  map.points.push(...regionPoints);
  sidecar.regions=[{...structuredClone(data.clusters[0]),label:'product development',
    membershipHash:createHash('sha256').update(JSON.stringify(regionPoints.map(p=>p.uri).sort())).digest('hex'),
    sources:regionPoints.map((p,i)=>({id:i+1,uri:p.uri,title:'Region document',excerpt:'Evidence'}))}];
  assert.deepEqual((await validate(sidecar,map)).map(c=>[c.level,c.id]),[['fine',7],['coarse',7]]);
  sidecar.regions[0].sources[0].uri=atlas.points[0].uri;
  await assert.rejects(validate(sidecar,map));
});
