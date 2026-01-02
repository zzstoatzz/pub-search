const std = @import("std");

/// Generate dashboard HTML with live stats
pub fn render(
    alloc: std.mem.Allocator,
    uptime_secs: i64,
    searches: u64,
    errors: u64,
    documents: i64,
    publications: i64,
    tags_json: []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>leaflet search stats</title>
        \\  <style>
        \\    * { box-sizing: border-box; margin: 0; padding: 0; }
        \\    body {
        \\      font-family: monospace;
        \\      background: #0a0a0a;
        \\      color: #ccc;
        \\      min-height: 100vh;
        \\      padding: 2rem;
        \\      line-height: 1.6;
        \\    }
        \\    .container { max-width: 800px; margin: 0 auto; }
        \\    h1 { font-size: 14px; color: #888; margin-bottom: 2rem; font-weight: normal; }
        \\    h1 a { color: #1B7340; text-decoration: none; }
        \\    h1 a:hover { color: #2a9d5c; }
        \\    h2 { font-size: 12px; color: #666; margin: 2rem 0 1rem; font-weight: normal; text-transform: uppercase; letter-spacing: 1px; }
        \\    .stats-grid {
        \\      display: grid;
        \\      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
        \\      gap: 1rem;
        \\      margin-bottom: 2rem;
        \\    }
        \\    .stat {
        \\      background: #111;
        \\      border: 1px solid #222;
        \\      padding: 1rem;
        \\      border-radius: 4px;
        \\    }
        \\    .stat-value {
        \\      font-size: 24px;
        \\      color: #fff;
        \\      margin-bottom: 0.25rem;
        \\    }
        \\    .stat-value.uptime { color: #2a9d5c; }
        \\    .stat-label { font-size: 11px; color: #666; }
        \\    .tags-grid {
        \\      display: flex;
        \\      flex-wrap: wrap;
        \\      gap: 0.5rem;
        \\    }
        \\    .tag {
        \\      background: #151515;
        \\      border: 1px solid #252525;
        \\      padding: 0.5rem 0.75rem;
        \\      border-radius: 4px;
        \\      font-size: 12px;
        \\      color: #888;
        \\      text-decoration: none;
        \\    }
        \\    .tag:hover { background: #1a1a1a; border-color: #333; color: #aaa; }
        \\    .tag .count { color: #555; margin-left: 0.5rem; }
        \\    .footer { margin-top: 3rem; font-size: 11px; color: #444; }
        \\    .footer a { color: #555; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <h1><a href="https://leaflet-search.pages.dev">leaflet search</a> / stats</h1>
        \\
        \\    <div class="stats-grid">
        \\      <div class="stat">
        \\        <div class="stat-value uptime" id="uptime">--</div>
        \\        <div class="stat-label">uptime</div>
        \\      </div>
        \\      <div class="stat">
        \\        <div class="stat-value">
    );

    try w.print("{d}", .{searches});
    try w.writeAll(
        \\</div>
        \\        <div class="stat-label">searches (this session)</div>
        \\      </div>
        \\      <div class="stat">
        \\        <div class="stat-value">
    );

    try w.print("{d}", .{documents});
    try w.writeAll(
        \\</div>
        \\        <div class="stat-label">documents indexed</div>
        \\      </div>
        \\      <div class="stat">
        \\        <div class="stat-value">
    );

    try w.print("{d}", .{publications});
    try w.writeAll(
        \\</div>
        \\        <div class="stat-label">publications indexed</div>
        \\      </div>
        \\      <div class="stat">
        \\        <div class="stat-value">
    );

    try w.print("{d}", .{errors});
    try w.writeAll(
        \\</div>
        \\        <div class="stat-label">errors</div>
        \\      </div>
        \\    </div>
        \\
        \\    <h2>top tags</h2>
        \\    <div class="tags-grid" id="tags"></div>
        \\
        \\    <div class="footer">
        \\      <a href="https://tangled.sh/@zzstoatzz.io/leaflet-search" target="_blank">source</a>
        \\    </div>
        \\  </div>
        \\
        \\  <script>
        \\    const startUptime =
    );

    try w.print("{d}", .{uptime_secs});
    try w.writeAll(
        \\;
        \\    const startTime = Date.now();
        \\
        \\    function formatUptime(secs) {
        \\      const d = Math.floor(secs / 86400);
        \\      const h = Math.floor((secs % 86400) / 3600);
        \\      const m = Math.floor((secs % 3600) / 60);
        \\      const s = secs % 60;
        \\      if (d > 0) return `${d}d ${h}h ${m}m`;
        \\      if (h > 0) return `${h}h ${m}m ${s}s`;
        \\      if (m > 0) return `${m}m ${s}s`;
        \\      return `${s}s`;
        \\    }
        \\
        \\    function updateUptime() {
        \\      const elapsed = Math.floor((Date.now() - startTime) / 1000);
        \\      document.getElementById('uptime').textContent = formatUptime(startUptime + elapsed);
        \\    }
        \\
        \\    updateUptime();
        \\    setInterval(updateUptime, 1000);
        \\
        \\    const tags =
    );

    try w.writeAll(tags_json);
    try w.writeAll(
        \\;
        \\    const tagsHtml = tags.slice(0, 20).map(t =>
        \\      `<a class="tag" href="https://leaflet-search.pages.dev/?tag=${encodeURIComponent(t.tag)}">${t.tag}<span class="count">${t.count}</span></a>`
        \\    ).join('');
        \\    document.getElementById('tags').innerHTML = tagsHtml;
        \\  </script>
        \\</body>
        \\</html>
    );

    return buf.toOwnedSlice(alloc);
}
