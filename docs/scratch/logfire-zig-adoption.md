# logfire-zig adoption guide for leaflet-search

guide for integrating logfire-zig into the leaflet-search backend.

## 1. add dependency

in `backend/build.zig.zon`:

```zig
.dependencies = .{
    // ... existing deps ...
    .logfire = .{
        .url = "https://tangled.sh/zzstoatzz.io/logfire-zig/archive/main",
        .hash = "...", // run zig build to get hash
    },
},
```

in `backend/build.zig`, add the import:

```zig
const logfire = b.dependency("logfire", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("logfire", logfire.module("logfire"));
```

## 2. configure in main.zig

```zig
const std = @import("std");
const logfire = @import("logfire");
// ... other imports ...

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // configure logfire early
    // reads LOGFIRE_WRITE_TOKEN from env automatically
    const lf = try logfire.configure(.{
        .service_name = "leaflet-search",
        .service_version = "0.0.1",
        .environment = std.posix.getenv("FLY_APP_NAME") orelse "development",
    });
    defer lf.shutdown();

    logfire.info("starting leaflet-search on port {d}", .{port});

    // ... rest of main ...
}
```

## 3. replace timing.zig with spans

current pattern in server/mod.zig:

```zig
fn handleSearch(request: *http.Server.Request, target: []const u8) !void {
    const start_time = std.time.microTimestamp();
    defer timing.record(.search, start_time);
    // ...
}
```

with logfire:

```zig
fn handleSearch(request: *http.Server.Request, target: []const u8) !void {
    const span = logfire.span("search.handle", .{});
    defer span.end();

    // parse params
    const query = parseQueryParam(alloc, target, "q") catch "";

    // add attributes after parsing
    span.setAttribute("query", query);
    span.setAttribute("tag", tag_filter orelse "");

    // ...
}
```

for nested operations:

```zig
fn search(alloc: Allocator, query: []const u8, ...) ![]Result {
    const span = logfire.span("search.execute", .{
        .query_length = @intCast(query.len),
    });
    defer span.end();

    // FTS query
    {
        const fts_span = logfire.span("search.fts", .{});
        defer fts_span.end();
        // ... FTS logic ...
    }

    // vector search fallback
    if (results.len < limit) {
        const vec_span = logfire.span("search.vector", .{});
        defer vec_span.end();
        // ... vector search ...
    }

    return results;
}
```

## 4. add structured logging

replace `std.debug.print` with logfire:

```zig
// before
std.debug.print("accept error: {}\n", .{err});

// after
logfire.err("accept error: {}", .{err});
```

```zig
// before
std.debug.print("{s} listening on http://0.0.0.0:{d}\n", .{app_name, port});

// after
logfire.info("{s} listening on port {d}", .{app_name, port});
```

for sync operations in tap.zig:

```zig
logfire.info("sync complete", .{});
logfire.debug("processed {d} events", .{event_count});
```

for errors:

```zig
logfire.err("turso query failed: {}", .{@errorName(err)});
```

## 5. add metrics

replace stats.zig counters with logfire metrics:

```zig
// before (in stats.zig)
pub fn recordSearch(query: []const u8) void {
    total_searches.fetchAdd(1, .monotonic);
    // ...
}

// with logfire (in server/mod.zig or stats.zig)
pub fn recordSearch(query: []const u8) void {
    logfire.counter("search.total", 1);
    // existing logic...
}
```

for gauges (e.g., active connections, document counts):

```zig
logfire.gaugeInt("documents.indexed", doc_count);
logfire.gaugeInt("connections.active", active_count);
```

for latency histograms (more detail than counter):

```zig
// after search completes
logfire.metric(.{
    .name = "search.latency_ms",
    .unit = "ms",
    .data = .{
        .histogram = .{
            .data_points = &[_]logfire.HistogramDataPoint{.{
                .start_time_ns = start_ns,
                .time_ns = std.time.nanoTimestamp(),
                .count = 1,
                .sum = latency_ms,
                .bucket_counts = ...,
                .explicit_bounds = ...,
                .min = latency_ms,
                .max = latency_ms,
            }},
        },
    },
});
```

## 6. deployment

add to fly.toml secrets:

```bash
fly secrets set LOGFIRE_WRITE_TOKEN=pylf_v1_us_xxxxx --app leaflet-search-backend
```

logfire-zig reads from `LOGFIRE_WRITE_TOKEN` or `LOGFIRE_TOKEN` automatically.

## 7. what to keep from existing code

**keep timing.zig** - it provides local latency histograms for the dashboard API. logfire spans complement this with distributed tracing.

**keep stats.zig** - local counters are still useful for the `/stats` endpoint. logfire metrics add remote observability.

**keep activity.zig** - tracks recent activity for the dashboard. orthogonal to logfire.

the pattern is: local state for dashboard UI, logfire for observability.

## 8. migration order

1. add dependency, configure in main.zig
2. add spans to request handlers (search, similar, tags, popular)
3. add structured logging for errors and important events
4. add metrics for key counters
5. gradually replace `std.debug.print` with logfire logging
6. consider removing timing.zig if logfire histograms are sufficient

## 9. example: full search handler

```zig
fn handleSearch(request: *http.Server.Request, target: []const u8) !void {
    const span = logfire.span("http.search", .{});
    defer span.end();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const query = parseQueryParam(alloc, target, "q") catch "";
    const tag_filter = parseQueryParam(alloc, target, "tag") catch null;

    if (query.len == 0 and tag_filter == null) {
        logfire.debug("empty search request", .{});
        try sendJson(request, "{\"error\":\"enter a search term\"}");
        return;
    }

    const results = search.search(alloc, query, tag_filter, null, null) catch |err| {
        logfire.err("search failed: {}", .{@errorName(err)});
        stats.recordError();
        return err;
    };

    logfire.counter("search.requests", 1);
    logfire.info("search completed", .{});

    // ... send response ...
}
```

## 10. verifying it works

run locally:

```bash
LOGFIRE_WRITE_TOKEN=pylf_v1_us_xxx zig build run
```

check logfire dashboard for traces from `leaflet-search` service.

without token (console fallback):

```bash
zig build run
# prints [span], [info], [metric] to stderr
```
