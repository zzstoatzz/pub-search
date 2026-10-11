import assert from 'node:assert/strict';
import test from 'node:test';
import '../../site/atlas-view.js';
const {decode}=globalThis.AtlasView;
const view=()=>({version:1,meta:{generatedAt:'now'},clusters:{coarse:[],fine:[]},publications:[],
 platforms:['leaflet','whitewind'],dids:['did:plc:b','did:plc:a'],collections:['site.standard.document','com.whtwnd.blog.entry'],basePaths:['b.example',''],
 points:{index:[1,2,0],x:[-10000,0,1349],y:[10000,1,-48],platform:[1,0,0],did:[1,0,0],collection:[1,0,0],rkey:['zz','aa','3mrkey'],basePath:[1,0,0],
  title:['','posts/aa and aa','Café — notes'],path:['','/posts/\x01/\x01.html','/\x01'],clusterCoarse:[2,2,-1],clusterFine:[-1,7,7]}});
test('columns decode to atlas.json points in the original order',()=>{
 assert.deepEqual(decode(view()).points,[
  {x:0.1349,y:-0.0048,uri:'at://did:plc:b/site.standard.document/3mrkey',title:'Café — notes',platform:'leaflet',basePath:'b.example',path:'/3mrkey',clusterCoarse:-1,clusterFine:7},
  {x:-1,y:1,uri:'at://did:plc:a/com.whtwnd.blog.entry/zz',title:'',platform:'whitewind',basePath:'',path:'',clusterCoarse:2,clusterFine:-1},
  {x:0,y:0.0001,uri:'at://did:plc:b/site.standard.document/aa',title:'posts/aa and aa',platform:'leaflet',basePath:'b.example',path:'/posts/aa/aa.html',clusterCoarse:2,clusterFine:7}]);
});
test('coordinates decode to the same doubles the json literals parse to',()=>{
 for(let n=-10000;n<=10000;n+=7) assert.equal(n/10000,JSON.parse((n/10000).toFixed(4)));
});
test('a view that is not sound is refused so the page falls back to atlas.json.gz',()=>{
 const bad=[v=>{v.version=2;},v=>{v.points.title.pop();},v=>{v.points.index=[0,0,1];},v=>{v.points.index=[0,1,3];},v=>{delete v.points.rkey;}];
 for(const change of bad){const v=view();change(v);assert.throws(()=>decode(v));}
 assert.throws(()=>decode(null));
});
