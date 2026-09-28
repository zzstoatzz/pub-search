import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import '../../site/atlas-summaries.js';
const {validate, hitTest} = globalThis.AtlasSummaries;
const atlas = {meta:{generatedAt:'today'},clusters:{fine:[{id:7,label:'agents'}]},points:[1,2,3].map(i=>({uri:`at://did:plc:a/site.standard.document/${i}`,clusterFine:7}))};
const data = {version:2,status:'ready',atlasGeneratedAt:'today',clusters:[{id:7,label:'agents',memberCount:3,membershipHash:createHash('sha256').update(JSON.stringify(atlas.points.map(p=>p.uri).sort())).digest('hex'),summary:'Software agents coordinate tasks.',sourceIds:[1],sources:atlas.points.map((p,i)=>({id:i+1,uri:p.uri,title:'Document',excerpt:'Content'}))}]};
test('accepts summaries tied to exact memberships',async()=>assert.equal(await validate(data,atlas),data.clusters));
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
