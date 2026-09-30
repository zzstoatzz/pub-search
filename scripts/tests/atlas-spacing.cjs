const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const context={};vm.createContext(context);vm.runInContext(fs.readFileSync('site/atlas-spacing.js','utf8'),context);
test('worker spacing agrees with a brute-force search across cell boundaries and coincident points',()=>{
  const x=Float32Array.from([0,0,.0059,.0061,-.003,1]),y=Float32Array.from([0,0,.002,.002,-.002,1]);
  const result=context.atlasPointSpacing(x,y);
  for(let i=0;i<x.length;i++){
    let best=.006**2;
    for(let j=0;j<x.length;j++) if(i!==j) best=Math.min(best,(x[i]-x[j])**2+(y[i]-y[j])**2);
    assert.equal(result[i],Math.fround(Math.sqrt(best)));
  }
});
