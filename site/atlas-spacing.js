  function atlasPointSpacing(pointsX, pointsY) {
    var cs = 0.006, cells = new Map(), n = pointsX.length;
    var pointSpacing = new Float32Array(n);
    for (var i = 0; i < n; i++) {
      var key = Math.floor(pointsX[i] / cs) + ',' + Math.floor(pointsY[i] / cs);
      if (!cells.has(key)) cells.set(key, []);
      cells.get(key).push(i);
    }
    for (var i = 0; i < n; i++) {
      var gx = Math.floor(pointsX[i] / cs), gy = Math.floor(pointsY[i] / cs), best = cs * cs;
      for (var x = gx - 1; x <= gx + 1; x++) for (var y = gy - 1; y <= gy + 1; y++) {
        var cell = cells.get(x + ',' + y);
        if (!cell) continue;
        for (var k = 0; k < cell.length; k++) {
          var j = cell[k];
          if (j === i) continue;
          var dx = pointsX[i] - pointsX[j], dy = pointsY[i] - pointsY[j];
          best = Math.min(best, dx * dx + dy * dy);
        }
      }
      pointSpacing[i] = Math.sqrt(best);
    }
    return pointSpacing;
  }
