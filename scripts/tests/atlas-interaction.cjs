const assert = require('node:assert/strict');
require(process.argv[2] ? require('node:path').resolve(process.argv[2]) : '../../site/atlas-interaction.js');
const {gesture,pick}=globalThis.AtlasInteraction;
let selected=[], transforms=[];
const state=gesture({select:(...args)=>selected.push(args),transform:(...args)=>transforms.push(args),hover:()=>{},leave:()=>{}});
const event=(id,x,y,type='touch')=>({pointerId:id,clientX:x,clientY:y,pointerType:type,button:0});
state.down(event(1,100,100));state.move(event(1,105,103));state.up(event(1,105,103));
assert.equal(selected.length,1,'finger jitter should still select');
assert.equal(transforms.length,0,'finger jitter should not move the map');
state.down(event(1,100,100));state.move(event(1,120,100));state.move(event(1,140,100));state.move(event(1,100,100));state.up(event(1,100,100));
assert.equal(selected.length,1,'returning a drag to its start must not tap');
assert.equal(transforms.length,2);
state.down(event(1,100,100));state.down(event(2,200,100));state.move(event(2,250,100));state.up(event(2,250,100));state.move(event(1,105,100));state.up(event(1,105,100));
assert.equal(selected.length,1,'pinch to single finger must not tap');
assert.equal(transforms[2][4],1.5);
state.down(event(1,100,100));state.abort(event(1,100,100));state.up(event(1,100,100));
assert.equal(selected.length,1,'cancelled gesture must not select');
state.down(event(1,100,100,'mouse'));state.up(event(1,100,100,'mouse'));
assert.equal(selected.length,2,'new click works after cancellation');
const small={index:0,sx:100,sy:100,r:4},large={index:1,sx:125,sy:100,r:18};
assert.equal(pick([small],120,100,'touch'),small,'small publisher has finger reach');
assert.equal(pick([small],120,100,'mouse'),null);
assert.equal(pick([small,large],108,100,'touch'),large,'visible surface beats nearby expanded target');
assert.equal(pick([small,large],100,100,'touch'),small);
console.log('PASS: jitter, drag-return, pinch-to-pan, cancellation, subsequent clicks, screen-space reach and overlapping targets');

const test = require('node:test');
function fixture() {
  const moves = [], taps = [];
  let starts = 0;
  const input = gesture({
    start: () => { starts++; },
    transform: (...args) => moves.push(args),
    select: (...args) => taps.push(args),
    hover: () => {}, leave: () => {},
  });
  const finger = (id, x, primary = false, buttons = 1) => ({
    pointerId: id, clientX: x, clientY: 100,
    pointerType: 'touch', button: 0, buttons, isPrimary: primary,
  });
  return {input, moves, taps, finger, starts: () => starts};
}
test('a new primary contact clears a finger whose end event was lost', () => {
  const {input, moves, taps, finger} = fixture();
  input.down(finger(1, 100, true));
  input.down(finger(2, 200));
  input.move(finger(2, 240));
  input.up(finger(2, 240));
  input.down(finger(3, 200, true));
  input.move(finger(3, 230, true));
  input.move(finger(3, 260, true));
  assert.equal(moves.at(-1)[4], 1, 'single-finger drag must not scale');
  input.up(finger(3, 260, true));
  assert.equal(taps.length, 0);
});
test('lifting either pinch contact continues as a pan', () => {
  for (const remaining of [1, 2]) {
    const {input, moves, finger} = fixture();
    input.down(finger(1, 100, true)); input.down(finger(2, 200));
    input.move(finger(2, 240));
    input.up(finger(remaining === 1 ? 2 : 1, remaining === 1 ? 240 : 100));
    input.move(finger(remaining, remaining === 1 ? 130 : 270));
    assert.equal(moves.at(-1)[4], 1);
    assert.equal(moves.at(-1)[2] - moves.at(-1)[0], 30);
  }
});
test('canceling either pinch contact cannot leave a zooming drag', () => {
  for (const remaining of [1, 2]) {
    const {input, moves, finger} = fixture();
    input.down(finger(1, 100, true)); input.down(finger(2, 200));
    input.abort(finger(remaining === 1 ? 2 : 1, 100));
    input.move(finger(remaining, remaining === 1 ? 130 : 230));
    assert.equal(moves.at(-1)[4], 1);
  }
});
test('lifecycle reset ends a pinch and allows the next gesture', () => {
  const {input, moves, taps, finger} = fixture();
  input.down(finger(1, 100, true)); input.down(finger(2, 200));
  input.reset();
  input.up(finger(1, 100)); input.up(finger(2, 200));
  assert.equal(taps.length, 0);
  input.down(finger(3, 100, true));
  input.move(finger(3, 130, true)); input.move(finger(3, 160, true));
  assert.equal(moves.at(-1)[4], 1);
});
test('a no-contact move removes the stale pointer instead of zooming', () => {
  const {input, moves, finger} = fixture();
  input.down(finger(1, 100, true)); input.down(finger(2, 200));
  input.move(finger(1, 100, true, 0));
  input.move(finger(2, 230));
  assert.equal(moves.at(-1)[4], 1);
});
test('primary is per contact sequence, not a reason to reset each move', () => {
  const {input, moves, finger, starts} = fixture();
  input.down(finger(1, 100, true)); input.down(finger(2, 200));
  input.move(finger(1, 50, true));
  assert.equal(moves.at(-1)[4], 1.5);
  assert.equal(starts(), 2);
});

test('topic framing fits every member in the uncovered phone and desktop map', () => {
  const points=[{x:-.4,y:-.1},{x:.25,y:.3},{x:.1,y:-.2}];
  for(const [width,height,rect] of [[390,844,{left:24,top:84,right:366,bottom:360}], [1280,800,{left:24,top:84,right:864,bottom:776}]]) {
    const target=globalThis.AtlasInteraction.frameTopic(points,[0,1,2],rect,width,height,.5,500);
    const scale=Math.min(width,height)*.42*target.zoom;
    for(const p of points) {
      const x=width/2+(p.x-target.x)*scale,y=height/2+(p.y-target.y)*scale;
      assert.ok(x>=rect.left && x<=rect.right && y>=rect.top && y<=rect.bottom,'member is obscured by the summary or page chrome');
    }
    const smaller=globalThis.AtlasInteraction.frameTopic(points.map(p=>({x:p.x/10,y:p.y/10})),[0,1,2],rect,width,height,.5,500);
    assert.ok(smaller.zoom>target.zoom*5,'small cluster should receive a closer view');
  }
  assert.equal(globalThis.AtlasInteraction.frameTopic(points,[],{},390,844,.5,500),null);
});
test('isolated outliers do not pull the camera away from the cluster core',()=>{
  const points=Array.from({length:100},(_,i)=>({x:(i%10)*.001,y:Math.floor(i/10)*.001}));
  points.push({x:2,y:2});
  const target=globalThis.AtlasInteraction.frameTopic(points,points.map((_,i)=>i),{left:24,top:84,right:366,bottom:360},390,844,.5,500);
  assert.ok(target.zoom>20);
});

test('camera flight keeps its destination on screen and pulls back for long pans', () => {
  const {flight}=globalThis.AtlasInteraction;
  const offset=(view,to)=>Math.hypot(to.x-view.x,to.y-view.y)/view.w;
  // overview to a nearby cluster, 27x zoom: the old independent lerp sent the cluster ~6x further off-centre mid-flight
  const from={x:0,y:0,w:2.38}, to={x:0.3,y:0.2,w:0.087};
  const path=flight(from,to);
  assert.deepEqual(path.at(0),from);
  assert.deepEqual(path.at(1),to);
  let peak=0, previous=from.w;
  for (let i=0;i<=100;i++) {
    const view=path.at(i/100);
    peak=Math.max(peak,offset(view,to));
    assert.ok(view.w<=previous+1e-9,'zooming in never backs out');
    previous=view.w;
  }
  assert.ok(peak<0.6,'destination stays inside the view: peak offset '+peak+' view widths');
  // two tight views far apart: zoom out to travel, then back in
  const far=flight({x:0,y:0,w:0.05},{x:1,y:0,w:0.05});
  assert.ok(far.at(0.5).w>0.5,'long pan pulls back');
  assert.ok(far.length>path.length,'longer journeys report a longer length');
  // zoom with no pan
  const still=flight({x:1,y:1,w:1},{x:1,y:1,w:0.25});
  assert.deepEqual(still.at(1),{x:1,y:1,w:0.25});
  assert.ok(Math.abs(still.at(0.5).w-0.5)<1e-9,'zoom interpolates geometrically');
});
