const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const db = @import("db/mod.zig");

// JSON output types
const TagJson = struct { tag: []const u8, count: i64 };
const TimelineJson = struct { date: []const u8, count: i64 };
const PubJson = struct { name: []const u8, basePath: []const u8, count: i64 };

/// All data needed to render the dashboard
pub const Data = struct {
    started_at: i64,
    searches: i64,
    publications: i64,
    articles: i64,
    looseleafs: i64,
    tags_json: []const u8,
    timeline_json: []const u8,
    top_pubs_json: []const u8,
};

// all dashboard queries batched into one request
const STATS_SQL =
    \\SELECT
    \\  (SELECT COUNT(*) FROM documents) as docs,
    \\  (SELECT COUNT(*) FROM publications) as pubs,
    \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
    \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
    \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at
;

const DOC_TYPES_SQL =
    \\SELECT
    \\  SUM(CASE WHEN publication_uri != '' THEN 1 ELSE 0 END) as articles,
    \\  SUM(CASE WHEN publication_uri = '' OR publication_uri IS NULL THEN 1 ELSE 0 END) as looseleafs
    \\FROM documents
;

const TAGS_SQL =
    \\SELECT tag, COUNT(*) as count
    \\FROM document_tags
    \\GROUP BY tag
    \\ORDER BY count DESC
    \\LIMIT 100
;

const TIMELINE_SQL =
    \\SELECT DATE(created_at) as date, COUNT(*) as count
    \\FROM documents
    \\WHERE created_at IS NOT NULL AND created_at != ''
    \\GROUP BY DATE(created_at)
    \\ORDER BY date DESC
    \\LIMIT 30
;

const TOP_PUBS_SQL =
    \\SELECT p.name, p.base_path, COUNT(d.uri) as doc_count
    \\FROM publications p
    \\JOIN documents d ON d.publication_uri = p.uri
    \\GROUP BY p.uri
    \\ORDER BY doc_count DESC
    \\LIMIT 8
;

pub fn fetch(alloc: Allocator) !Data {
    const client = db.getClient() orelse return error.NotInitialized;

    // batch all 5 queries into one HTTP request
    var batch = client.queryBatch(&.{
        .{ .sql = STATS_SQL },
        .{ .sql = DOC_TYPES_SQL },
        .{ .sql = TAGS_SQL },
        .{ .sql = TIMELINE_SQL },
        .{ .sql = TOP_PUBS_SQL },
    }) catch return error.QueryFailed;
    defer batch.deinit();

    // extract stats (query 0)
    const stats_row = batch.getFirst(0);
    const started_at = if (stats_row) |r| r.int(4) else 0;
    const searches = if (stats_row) |r| r.int(2) else 0;
    const publications = if (stats_row) |r| r.int(1) else 0;

    // extract doc types (query 1)
    const doc_row = batch.getFirst(1);
    const articles = if (doc_row) |r| r.int(0) else 0;
    const looseleafs = if (doc_row) |r| r.int(1) else 0;

    return .{
        .started_at = started_at,
        .searches = searches,
        .publications = publications,
        .articles = articles,
        .looseleafs = looseleafs,
        .tags_json = try formatTagsJson(alloc, batch.get(2)),
        .timeline_json = try formatTimelineJson(alloc, batch.get(3)),
        .top_pubs_json = try formatPubsJson(alloc, batch.get(4)),
    };
}

fn formatTagsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatTimelineJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatPubsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(PubJson{ .name = row.text(0), .basePath = row.text(1), .count = row.int(2) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Generate dashboard HTML with stats and charts
pub fn render(alloc: Allocator, data: Data) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(alloc);

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>leaflet search / stats</title>
        \\  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect x='4' y='18' width='6' height='10' fill='%231B7340'/><rect x='13' y='12' width='6' height='16' fill='%231B7340'/><rect x='22' y='6' width='6' height='22' fill='%231B7340'/></svg>">
        \\  <style>
        \\    * { box-sizing: border-box; margin: 0; padding: 0; }
        \\    body {
        \\      font-family: monospace;
        \\      background: #0a0a0a;
        \\      color: #ccc;
        \\      min-height: 100vh;
        \\      padding: 1rem;
        \\      font-size: 14px;
        \\      line-height: 1.6;
        \\    }
        \\    .container { max-width: 600px; margin: 0 auto; }
        \\    a { color: #1B7340; text-decoration: none; }
        \\    a:hover { color: #2a9d5c; }
        \\    h1 {
        \\      font-size: 12px;
        \\      font-weight: normal;
        \\      margin-bottom: 1.5rem;
        \\    }
        \\    h1 a.title { color: #888; }
        \\    h1 a.title:hover { color: #fff; }
        \\    h1 .dim { color: #555; }
        \\    section { margin-bottom: 2rem; }
        \\    .section-title {
        \\      font-size: 11px;
        \\      color: #555;
        \\      margin-bottom: 0.75rem;
        \\    }
        \\    .metrics {
        \\      display: flex;
        \\      gap: 1.5rem;
        \\      margin-bottom: 1rem;
        \\    }
        \\    .metric-value {
        \\      font-size: 16px;
        \\      color: #888;
        \\      font-weight: normal;
        \\    }
        \\    .metric-label {
        \\      font-size: 10px;
        \\      color: #444;
        \\      text-transform: uppercase;
        \\      letter-spacing: 0.5px;
        \\    }
        \\    .chart-box {
        \\      background: #111;
        \\      border: 1px solid #222;
        \\      padding: 1rem;
        \\      margin-bottom: 1rem;
        \\    }
        \\    .chart-header {
        \\      display: flex;
        \\      justify-content: space-between;
        \\      font-size: 11px;
        \\      color: #666;
        \\      margin-bottom: 0.75rem;
        \\    }
        \\    .timeline {
        \\      display: flex;
        \\      align-items: flex-end;
        \\      gap: 2px;
        \\      height: 60px;
        \\    }
        \\    .bar {
        \\      flex: 1;
        \\      background: #1B7340;
        \\      min-height: 2px;
        \\    }
        \\    .bar:hover { background: #2a9d5c; }
        \\    .doc-row {
        \\      display: flex;
        \\      justify-content: space-between;
        \\      font-size: 12px;
        \\      padding: 0.25rem 0;
        \\      border-bottom: 1px solid #1a1a1a;
        \\    }
        \\    .doc-row:last-child { border-bottom: none; }
        \\    .doc-type { color: #888; }
        \\    .doc-count { color: #ccc; }
        \\    .pub-row {
        \\      display: flex;
        \\      justify-content: space-between;
        \\      font-size: 12px;
        \\      padding: 0.25rem 0;
        \\      border-bottom: 1px solid #1a1a1a;
        \\    }
        \\    .pub-row:last-child { border-bottom: none; }
        \\    .pub-name { color: #888; }
        \\    .pub-count { color: #666; }
        \\    .tags {
        \\      display: flex;
        \\      flex-wrap: wrap;
        \\      gap: 0.5rem;
        \\    }
        \\    .tag {
        \\      font-size: 11px;
        \\      padding: 3px 8px;
        \\      background: #151515;
        \\      border: 1px solid #252525;
        \\      border-radius: 3px;
        \\      color: #777;
        \\    }
        \\    .tag:hover {
        \\      background: #1a1a1a;
        \\      border-color: #333;
        \\      color: #aaa;
        \\    }
        \\    .tag .n { color: #444; margin-left: 4px; }
        \\    .live { font-size: 11px; color: #555; }
        \\    .live span { color: #4ade80; }
        \\    footer {
        \\      margin-top: 2rem;
        \\      padding-top: 1rem;
        \\      border-top: 1px solid #222;
        \\      font-size: 11px;
        \\      color: #444;
        \\    }
        \\    footer a { color: #555; }
        \\    footer a:hover { color: #888; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="container">
        \\    <h1><a href="https://leaflet-search.pages.dev" class="title">leaflet search</a> <span class="dim">/ stats</span></h1>
        \\
        \\    <section>
        \\      <div class="metrics">
        \\        <div>
        \\          <div class="metric-value" id="age">--</div>
        \\          <div class="metric-label">uptime</div>
        \\        </div>
        \\        <div>
        \\          <div class="metric-value">
    );

    try w.print("{d}", .{data.searches});
    try w.writeAll(
        \\</div>
        \\          <div class="metric-label">searches</div>
        \\        </div>
        \\        <div>
        \\          <div class="metric-value">
    );

    try w.print("{d}", .{data.publications});
    try w.writeAll(
        \\</div>
        \\          <div class="metric-label">publications</div>
        \\        </div>
        \\      </div>
        \\      <div class="live" id="live"></div>
        \\    </section>
        \\
        \\    <section>
        \\      <div class="section-title">documents</div>
        \\      <div class="chart-box">
        \\        <div class="doc-row">
        \\          <span class="doc-type">articles</span>
        \\          <span class="doc-count">
    );

    try w.print("{d}", .{data.articles});
    try w.writeAll(
        \\</span>
        \\        </div>
        \\        <div class="doc-row">
        \\          <span class="doc-type">looseleafs</span>
        \\          <span class="doc-count">
    );

    try w.print("{d}", .{data.looseleafs});
    try w.writeAll(
        \\</span>
        \\        </div>
        \\      </div>
        \\    </section>
        \\
        \\    <section>
        \\      <div class="section-title">activity (last 30 days)</div>
        \\      <div class="chart-box">
        \\        <div class="timeline" id="timeline"></div>
        \\      </div>
        \\    </section>
        \\
        \\    <section>
        \\      <div class="section-title">top publications</div>
        \\      <div class="chart-box">
        \\        <div id="pubs"></div>
        \\      </div>
        \\    </section>
        \\
        \\    <section>
        \\      <div class="section-title">tags</div>
        \\      <div class="tags" id="tags"></div>
        \\    </section>
        \\
        \\    <footer>
        \\      <a href="https://leaflet-search.pages.dev">← back</a> · source on <a href="https://tangled.sh/@zzstoatzz.io/leaflet-search">tangled</a>
        \\    </footer>
        \\  </div>
        \\
        \\  <script>
        \\    const startedAt =
    );

    try w.print("{d}", .{data.started_at});
    try w.writeAll(" * 1000;\n    const tags = ");
    try w.writeAll(data.tags_json);
    try w.writeAll(";\n    const timeline = ");
    try w.writeAll(data.timeline_json);
    try w.writeAll(";\n    const pubs = ");
    try w.writeAll(data.top_pubs_json);
    try w.writeAll(
        \\;
        \\
        \\    function formatAge(ms) {
        \\      const s = Math.floor(ms / 1000);
        \\      const d = Math.floor(s / 86400);
        \\      const h = Math.floor((s % 86400) / 3600);
        \\      const m = Math.floor((s % 3600) / 60);
        \\      const sec = s % 60;
        \\      if (d > 0) return d + 'd ' + h + 'h ' + m + 'm ' + sec + 's';
        \\      if (h > 0) return h + 'h ' + m + 'm ' + sec + 's';
        \\      return m + 'm ' + sec + 's';
        \\    }
        \\    function updateAge() {
        \\      document.getElementById('age').textContent = formatAge(Date.now() - startedAt);
        \\    }
        \\    updateAge();
        \\    setInterval(updateAge, 1000);
        \\
        \\    // timeline
        \\    const timelineEl = document.getElementById('timeline');
        \\    if (timeline.length > 0) {
        \\      const max = Math.max(...timeline.map(d => d.count));
        \\      [...timeline].reverse().forEach(d => {
        \\        const h = max > 0 ? (d.count / max * 100) : 0;
        \\        const bar = document.createElement('div');
        \\        bar.className = 'bar';
        \\        bar.style.height = Math.max(h, 3) + '%';
        \\        bar.title = d.date + ': ' + d.count;
        \\        timelineEl.appendChild(bar);
        \\      });
        \\    }
        \\
        \\    // publications
        \\    const pubsEl = document.getElementById('pubs');
        \\    pubs.forEach(p => {
        \\      const row = document.createElement('div');
        \\      row.className = 'pub-row';
        \\      row.innerHTML = '<span class="pub-name">' + p.name + '</span><span class="pub-count">' + p.count + '</span>';
        \\      pubsEl.appendChild(row);
        \\    });
        \\
        \\    // tags
        \\    document.getElementById('tags').innerHTML = tags.slice(0, 20).map(t =>
        \\      '<a class="tag" href="https://leaflet-search.pages.dev/?tag=' + encodeURIComponent(t.tag) + '">' +
        \\        t.tag + '<span class="n">' + t.count + '</span></a>'
        \\    ).join('');
        \\
        \\    // live activity - just a number
        \\    const liveEl = document.getElementById('live');
        \\    let lastN = -1;
        \\    async function pollLive() {
        \\      try {
        \\        const r = await fetch('/activity');
        \\        const c = await r.json();
        \\        const n = c.reduce((a,b) => a+b, 0);
        \\        if (n !== lastN) {
        \\          liveEl.innerHTML = n > 0 ? '<span>' + n + '</span> req/6s' : '';
        \\          lastN = n;
        \\        }
        \\      } catch(e) {}
        \\    }
        \\    pollLive(); setInterval(pollLive, 1000);
        \\  </script>
        \\</body>
        \\</html>
    );

    return buf.toOwnedSlice(alloc);
}
