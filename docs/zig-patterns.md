# zig patterns

notes on zig idioms learned while building leaflet-search.

## json serialization

### struct serialization vs manual building

zig's `std.json.Stringify` can serialize structs directly with `jw.write(struct)`:

```zig
// define types that mirror the JSON structure
const Value = struct { type: []const u8 = "text", value: []const u8 };
const Stmt = struct { sql: []const u8, args: ?[]const Value = null };
const ExecuteReq = struct { type: []const u8 = "execute", stmt: Stmt };

// serialize with one call
try jw.write(ExecuteReq{ .stmt = .{ .sql = sql, .args = values } });
```

this is cleaner than manual field-by-field building:

```zig
// verbose alternative
try jw.beginObject();
try jw.objectField("type");
try jw.write("execute");
try jw.objectField("stmt");
try jw.beginObject();
try jw.objectField("sql");
try jw.write(sql);
// ... many more lines
try jw.endObject();
try jw.endObject();
```

### optional fields

use `emit_null_optional_fields = false` to omit null optional fields instead of serializing them as `"field": null`:

```zig
const Stmt = struct {
    sql: []const u8,
    args: ?[]const Value = null,  // optional field
};

var jw: json.Stringify = .{
    .writer = &body.writer,
    .options = .{ .emit_null_optional_fields = false },
};

// if args is null, the field is omitted entirely
try jw.write(Stmt{ .sql = "SELECT 1", .args = null });
// produces: {"sql":"SELECT 1"}
// NOT: {"sql":"SELECT 1","args":null}
```

this matters when APIs reject `null` values for optional fields (like Turso/Hrana).

## file organization

### file-as-type pattern

when a file IS a type (single primary struct), use `@This()`:

```zig
// Client.zig
const Client = @This();

allocator: Allocator,
url: []const u8,
// ... fields at top level

pub fn init(allocator: Allocator) !Client { ... }
pub fn query(self: *Client, ...) !Result { ... }
```

consumers import as: `const Client = @import("Client.zig");`

### namespace modules

when a file is a namespace with multiple types, use regular exports:

```zig
// result.zig
pub const Result = struct { ... };
pub const Row = struct { ... };
pub const BatchResult = struct { ... };
```

naming convention:
- `TitleCase.zig` → file-as-type (the file IS the struct)
- `snake_case.zig` → namespace module (exports multiple things)

## references

- [zig std.json.Stringify source](https://github.com/ziglang/zig/blob/master/lib/std/json/Stringify.zig)
- [zig style guide](https://ziglang.org/documentation/master/#Style-Guide)
