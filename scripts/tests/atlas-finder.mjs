import assert from 'node:assert/strict';
import test from 'node:test';
import '../../site/atlas-finder.js';
const {index,search}=globalThis.AtlasFinder;
const data={clusters:{coarse:[{id:1,label:'Software',count:200}],fine:[{id:2,label:'Agent memory',parent:1,count:50},{id:3,label:'Agent memory tools',parent:1,count:150}]},publications:[{name:'Agent Memory Journal',basePath:'journal.example',count:1000}],points:[{title:'Agent memory',uri:'at://one',clusterFine:2,clusterCoarse:1,basePath:'journal.example'},{title:'Café computing',uri:'at://two',clusterFine:3,clusterCoarse:1,basePath:'another.example'}]};
const entries=index(data);
test('exact topic names precede more popular prefix matches',()=>{
 const matches=search(entries,'AGENT MEMORY');
 assert.equal(matches[0].entry.kind,'topic');assert.equal(matches[0].rank,0);
 assert.ok(matches.findIndex(x=>x.entry.kind==='publication')>0);
});
test('hierarchy restricts navigation to the chosen region, topic, or publication',()=>{
 assert.deepEqual(search(entries,'',{kind:'region',id:1}).map(x=>x.entry.kind),['topic','topic']);
 assert.deepEqual(search(entries,'',{kind:'topic',id:2}).map(x=>x.entry.uri),['at://one']);
 assert.deepEqual(search(entries,'',{kind:'publication',basePath:'another.example'}).map(x=>x.entry.uri),['at://two']);
});
test('empty category browsing and accent-insensitive names remain searchable',()=>{
 assert.equal(search(entries,'',null,'publication').length,1);
 assert.equal(search(entries,'cafe')[0].entry.uri,'at://two');
 assert.equal(search(entries,'unknown').length,0);
});

test('document text search preserves author filters without treating quoted handles as filters',()=>{
 const url=new URL(globalThis.AtlasFinder.textUrl('memory @zzstoatzz.io'),'https://example.com');
 assert.equal(url.searchParams.get('author'),'zzstoatzz.io');
 assert.equal(url.searchParams.get('q'),'memory');
 assert.equal(new URL(globalThis.AtlasFinder.textUrl('@zzstoatzz.io'),'https://example.com').searchParams.get('mode'),'keyword');
 assert.equal(new URL(globalThis.AtlasFinder.textUrl('"@zzstoatzz.io"'),'https://example.com').searchParams.has('author'),false);
});
