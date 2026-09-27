(function(root) {
  function reach(type) { return type === 'mouse' ? 14 : 24; }
  function pick(nodes, x, y, type) {
    var best = null, score = Infinity;
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i], distance = Math.hypot(x - node.sx, y - node.sy);
      if (distance > Math.max(node.r, reach(type))) continue;
      var candidate = distance <= node.r ? distance / Math.max(1, node.r) - 2 : distance;
      if (candidate < score) { best = node; score = candidate; }
    }
    return best;
  }
  function gesture(callbacks) {
    var pointers = new Map(), moved = false, origin = null;
    function reset() { pointers.clear(); moved = true; origin = null; }
    function point(e) { return { x: e.clientX, y: e.clientY }; }
    function down(e) {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      if (e.isPrimary) reset();
      if (!pointers.size) { moved = false; origin = point(e); }
      if (callbacks.start) callbacks.start();
      pointers.set(e.pointerId, point(e));
      if (pointers.size > 1) moved = true;
    }
    function move(e) {
      if (e.buttons === 0 && pointers.has(e.pointerId)) { abort(e); return; }
      if (!pointers.has(e.pointerId)) {
        if (e.pointerType === 'mouse') callbacks.hover(e.clientX, e.clientY);
        return;
      }
      var previous = Array.from(pointers.values());
      var before = pointers.get(e.pointerId);
      pointers.set(e.pointerId, point(e));
      var current = Array.from(pointers.values());
      if (pointers.size >= 2) {
        var a = previous[0], b = previous[1], c = current[0], d = current[1];
        callbacks.transform((a.x+b.x)/2, (a.y+b.y)/2, (c.x+d.x)/2, (c.y+d.y)/2,
          Math.hypot(c.x-d.x,c.y-d.y)/Math.max(1,Math.hypot(a.x-b.x,a.y-b.y)));
      } else if (!moved) {
        if (Math.hypot(e.clientX-origin.x,e.clientY-origin.y) > (e.pointerType === 'mouse' ? 4 : 10)) moved = true;
      } else callbacks.transform(before.x,before.y,e.clientX,e.clientY,1);
    }
    function up(e) {
      if (!pointers.has(e.pointerId)) return;
      var tap = !moved && pointers.size === 1 && Math.hypot(e.clientX-origin.x,e.clientY-origin.y) <= (e.pointerType === 'mouse' ? 4 : 10);
      pointers.delete(e.pointerId);
      if (tap) callbacks.select(e.clientX,e.clientY,e.pointerType);
    }
    function abort(e) { if (pointers.has(e.pointerId)) { pointers.delete(e.pointerId); moved = true; } }
    return {down:down,move:move,up:up,abort:abort,reset:reset,leave:function(){ if (!pointers.size) callbacks.leave(); }};
  }
  function attach(canvas, callbacks) {
    var state = gesture(callbacks);
    canvas.addEventListener('pointerdown',function(e){
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      canvas.setPointerCapture(e.pointerId);
      state.down(e);
    });
    canvas.addEventListener('pointermove',state.move);
    var doc = canvas.ownerDocument;
    doc.addEventListener('pointerup',state.up);
    doc.addEventListener('pointercancel',state.abort);
    doc.defaultView.addEventListener('blur',state.reset);
    doc.addEventListener('visibilitychange',function(){ if (doc.hidden) state.reset(); });
    function endTouches(e) { if (!e.targetTouches.length) state.reset(); }
    canvas.addEventListener('touchend',endTouches);
    canvas.addEventListener('touchcancel',endTouches);
    canvas.addEventListener('lostpointercapture',state.abort);
    canvas.addEventListener('pointerleave',state.leave);
  }
  root.AtlasInteraction = {attach:attach,gesture:gesture,pick:pick,reach:reach};
})(typeof window === 'undefined' ? globalThis : window);
