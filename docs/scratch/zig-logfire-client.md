# zig logfire client - design notes

a potential official logfire client for zig. this document captures what would be useful from a practitioner's perspective, referencing existing implementations and protocol details.

## motivation

logfire has official clients for python, rust, and typescript. a zig client would enable observability for zig applications (like this one - leaflet-search) that want to participate in the pydantic/logfire ecosystem.

zig's growing use in performance-critical systems (databases, network services, game engines) makes it a natural fit. these are exactly the applications where observability matters most.

## what logfire actually is

logfire is an opinionated wrapper around opentelemetry. it's not a replacement - it's a distribution that:

1. simplifies configuration (single `configure()` call vs. wiring up providers/exporters manually)
2. provides ergonomic macros for structured logging and spans
3. sends data to logfire's platform (or any OTLP-compatible backend)
4. follows opentelemetry standards (OTLP protocol, semantic conventions, W3C trace context)

the key insight: you don't need to implement opentelemetry from scratch. you need to implement a thin wrapper that configures OTLP export and provides nice ergonomics.

## protocol details

from the [logfire alternative clients documentation](https://logfire.pydantic.dev/docs/how-to-guides/alternative-clients/):

**endpoints:**
- US: `https://logfire-us.pydantic.dev`
- EU: `https://logfire-eu.pydantic.dev`
- signals: `/v1/traces`, `/v1/metrics`, `/v1/logs`

**authentication:**
- header: `Authorization: {write-token}`
- token obtained from logfire project settings

**protocol:**
- HTTP with protobuf encoding (`http/protobuf`) - preferred
- HTTP with JSON encoding (`http/json`) - also supported
- no gRPC requirement

## reference: rust client architecture

the [logfire-rust](https://github.com/pydantic/logfire-rust) client (used in find-bufo) demonstrates the pattern:

```
src/
├── lib.rs           # public API, re-exports
├── config.rs        # LogfireConfigBuilder
├── exporters.rs     # OTLP exporter setup
├── logfire.rs       # core Logfire struct
├── macros/          # span!(), info!(), debug!(), etc.
├── metrics.rs       # counter, gauge, histogram
├── bridges/         # integration with tracing/log crates
└── internal/        # implementation details
```

key design decisions from rust client:

1. **builder pattern for configuration**
   ```rust
   let logfire = logfire::configure()
       .with_default_level_filter(LevelFilter::INFO)
       .finish()?;
   ```

2. **shutdown guard for clean exit**
   ```rust
   let _guard = logfire.shutdown_guard();
   // spans/logs flushed when guard drops
   ```

3. **structured logging macros**
   ```rust
   logfire::info!("search completed",
       query = &query_text,
       results_count = count as i64
   );
   ```

4. **span creation with attributes**
   ```rust
   let _span = logfire::span!(
       "turbopuffer.vector_search",
       query = &query,
       top_k = k as i64
   ).entered();
   ```

5. **wraps opentelemetry, doesn't replace it**
   - uses `opentelemetry-otlp` crate for export
   - uses `tracing` crate for span/event capture
   - provides bridge to integrate with existing tracing code

## what would be useful for zig

### configuration

```zig
const logfire = @import("logfire");

pub fn main() !void {
    const lf = try logfire.configure(.{
        .service_name = "leaflet-search",
        .default_level = .info,
    });
    defer lf.shutdown();

    // ...
}
```

environment variables should work automatically:
- `LOGFIRE_TOKEN` - required for sending to logfire
- `LOGFIRE_SERVICE_NAME` - optional override
- `OTEL_EXPORTER_OTLP_ENDPOINT` - for custom backends

### spans

```zig
const span = logfire.span("sync.full_sync", .{
    .doc_count = doc_count,
    .pub_count = pub_count,
});
defer span.end();

// work happens here
```

or with a callback pattern:

```zig
try logfire.withSpan("db.query", .{ .sql = sql }, struct {
    fn execute(ctx: *Context) !void {
        // work
    }
}.execute, &ctx);
```

### structured logging

```zig
logfire.info("search completed", .{
    .query = query,
    .results_count = @intCast(results.len),
    .latency_ms = timer.read() / std.time.ns_per_ms,
});

logfire.err("sync failed", .{
    .error = @errorName(err),
    .offset = offset,
});
```

the key is compile-time type safety on the structured fields while producing OTLP-compatible attribute encoding.

### metrics

```zig
const search_latency = logfire.histogram("search.latency_ms", .{
    .unit = "ms",
    .description = "search request latency",
});

// later
search_latency.record(elapsed_ms, .{ .endpoint = "/search" });
```

### what i'd actually use day-to-day

from working on leaflet-search, the most common patterns are:

1. **timing operations**
   ```zig
   const span = logfire.span("turso.query", .{ .sql = sql[0..@min(sql.len, 100)] });
   defer span.end();
   ```

2. **logging with context**
   ```zig
   logfire.info("sync complete", .{
       .docs = doc_count,
       .pubs = pub_count,
       .duration_ms = duration,
   });
   ```

3. **error tracking**
   ```zig
   logfire.err("query failed", .{
       .error = @errorName(err),
       .query = truncated_query,
   });
   ```

4. **request tracing** (if building HTTP services)
   - trace ID propagation via headers
   - automatic span creation for requests

## implementation considerations

### OTLP encoding

protobuf is preferred but requires either:
- generated zig code from `.proto` files
- hand-rolled protobuf encoder (OTLP schema is well-documented)

JSON encoding is simpler to implement and logfire supports it. could start with JSON and add protobuf later.

### batching and export

spans/logs should be batched and exported asynchronously to avoid blocking application code. this is where zig's async/threading model matters:

- batch buffer with configurable size/timeout
- background thread or async task for export
- graceful shutdown (flush on exit)

### allocator design

zig clients need to be explicit about allocation. options:

1. require allocator passed to `configure()`
2. use arena per batch, free on export
3. fixed-size buffers with overflow handling

### error handling

zig's explicit error handling is a strength here. export failures shouldn't crash the application:

```zig
lf.flush() catch |err| {
    std.log.warn("logfire export failed: {}", .{err});
};
```

## prior art

- [logfire-rust](https://github.com/pydantic/logfire-rust) - official rust client
- [opentelemetry-zig](https://github.com/open-telemetry/opentelemetry-zig) - community otel implementation (incomplete)
- [zig-opentelemetry](https://github.com/baaalad/zig-opentelemetry) - another community attempt

the opentelemetry-zig implementations are incomplete, which is actually an opportunity - a logfire-zig client could become the de facto OTLP implementation for zig.

## references

- [logfire docs](https://logfire.pydantic.dev/docs/)
- [alternative clients guide](https://logfire.pydantic.dev/docs/how-to-guides/alternative-clients/)
- [OTLP specification](https://opentelemetry.io/docs/specs/otlp/)
- [find-bufo](https://github.com/zzstoatzz/find-bufo) - rust app using logfire (src/main.rs, src/search.rs)
- [plyr.fm logfire docs](../scratch/../../../plyr.fm/docs/tools/logfire.md) - querying patterns

## open questions

1. should this be `logfire-zig` (pydantic-branded) or `zig-logfire` (community)?
2. JSON-first or protobuf-first?
3. how to handle trace context propagation for HTTP frameworks that don't exist yet in zig?
4. should it integrate with zig's `std.log` or provide its own logging?

---

*these are practitioner notes, not a specification. the goal is to inform implementation decisions while leaving room for the implementer to make the right choices.*
