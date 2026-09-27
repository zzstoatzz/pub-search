const frame = document.querySelector('iframe');
const results = document.querySelector('#results');
let win, canvas, points, gpuLimit, passed = 0, failed = 0;
const spacing = new Map();
const log = text => { results.textContent += text + '\n'; };
const assert = (value, message) => { if (!value) throw new Error(message); };
const state = () => win.atlas._debug();
const nextFrame = () => new Promise(resolve => win.requestAnimationFrame(resolve));
async function settle() { await nextFrame(); await nextFrame(); }
async function until(check) {
  const deadline = performance.now() + 20000;
  while (!check()) {
    if (performance.now() > deadline) throw new Error('Atlas did not become ready');
    await new Promise(resolve => setTimeout(resolve, 30));
  }
}
async function load(width, height) {
  frame.style.width = width + 'px'; frame.style.height = height + 'px';
  const center = points[Math.floor(points.length / 2)];
  await new Promise(resolve => {
    frame.onload = resolve;
    frame.src = `/site/atlas.html?x=${center.x}&y=${center.y}&z=80`;
  });
  win = frame.contentWindow;
  canvas = win.document.querySelector('#canvas');
  await until(() => win.atlas && win.document.querySelector('#loading').classList.contains('hidden'));
  await until(() => !state().animating);
  const gl = win.document.querySelector('#gl-canvas').getContext('webgl');
  gpuLimit = gl ? gl.getParameter(gl.ALIASED_POINT_SIZE_RANGE)[1] / (2.8 * win.devicePixelRatio) : Infinity;
  await settle();
}
function wheelTo(zoom, x = win.innerWidth / 2, y = win.innerHeight / 2) {
  canvas.dispatchEvent(new win.WheelEvent('wheel', {
    clientX: x, clientY: y, deltaY: Math.log(zoom / state().zoom) / Math.log(0.995),
    bubbles: true, cancelable: true,
  }));
}
function nearestSpacing(index) {
  if (spacing.has(index)) return spacing.get(index);
  const p = points[index];
  let best = 0.006 ** 2;
  for (let i = 0; i < points.length; i++) {
    if (i === index) continue;
    best = Math.min(best, (p.x - points[i].x) ** 2 + (p.y - points[i].y) ** 2);
  }
  const distance = Math.fround(Math.sqrt(best));
  spacing.set(index, distance);
  return distance;
}
function fullScan(platform) {
  const { zoom, panX, panY } = state();
  const width = win.innerWidth, height = win.innerHeight;
  const scale = Math.min(width, height) * 0.42 * zoom;
  const maxRadius = width < 600 ? 50 : 76;
  const radius = Math.min(gpuLimit, 1.2 + (maxRadius - 1.2) * (1 - Math.exp(-0.16 * zoom ** 0.92 / (maxRadius - 1.2))));
  const candidates = [];
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    if (platform && p.platform !== platform) continue;
    const x = width / 2 + (p.x + panX) * scale;
    const y = height / 2 + (p.y + panY) * scale;
    if (x + radius < 0 || x - radius > width || y + radius < 0 || y - radius > height) continue;
    const room = Math.max(1.2, nearestSpacing(i) * scale * 0.48);
    if (radius / (1 + (radius / room) ** 8) ** 0.125 <= 2) continue;
    candidates.push({i, d: (x - width / 2) ** 2 + (y - height / 2) ** 2});
  }
  return candidates.sort((a,b) => a.d - b.d || a.i - b.i).slice(0, width < 600 ? 48 : 80).map(p => p.i);
}
async function test(name, run) {
  try { await run(); passed++; log(`PASS ${name}`); }
  catch (error) { failed++; log(`FAIL ${name}: ${error.message}`); }
}
document.querySelector('#run').onclick = async () => {
  document.querySelector('#run').disabled = true;
  results.textContent = ''; passed = failed = 0;
  try {
    const response = await fetch('/site/atlas.json.gz');
    const data = await new Response(response.body.pipeThrough(new DecompressionStream('gzip'))).json();
    points = data.points.map(p => ({...p, x:Math.fround(p.x), y:Math.fround(p.y)}));
    for (const [width,height] of [[390,844],[1280,720]]) {
      log(`${width}×${height}`);
      await load(width,height);
      await test('spatial selection agrees with full scan and brute-force spacing', async () => {
        for (const zoom of [50,80,180,500]) {
          wheelTo(zoom, width / 2 + 17, height / 2 - 11);
          await settle();
          assert(JSON.stringify(state().planetIndices) === JSON.stringify(fullScan()), `selection differs at zoom ${zoom}`);
        }
      });
      await test('stationary rotation reuses selection', async () => {
        wheelTo(80); await settle();
        const before = state();
        assert(before.planetIndices.length > 0 && before.planetsActive, 'no planets');
        for (let i=0;i<12;i++) await nextFrame();
        assert(state().planetLayoutBuilds === before.planetLayoutBuilds, 'stationary layout rebuilt');
        assert(before.planetPointsVisited < points.length / 5, 'query visits most points');
        log(`  Visited ${before.planetPointsVisited}/${points.length} points; 12 frames reused layout.`);
      });
      await test('platform changes invalidate selection', async () => {
        const item = win.document.querySelector('[data-platform="leaflet"]');
        item.click(); await settle();
        assert(JSON.stringify(state().planetIndices) === JSON.stringify(fullScan('leaflet')), 'filter mismatch');
        item.click(); await settle();
        assert(JSON.stringify(state().planetIndices) === JSON.stringify(fullScan()), 'cleared filter mismatch');
      });
    }
  } catch(error) { failed++; log(`FAIL harness: ${error.stack}`); }
  log(`${passed} passed, ${failed} failed`);
  document.querySelector('#run').disabled = false;
};
document.querySelector('#phone').onclick = async () => {
  if (!points) return;
  await load(390,844);
  frame.scrollIntoView();
};
