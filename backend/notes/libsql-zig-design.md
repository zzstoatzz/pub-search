# libsql-zig design sketch

a zig client for turso/libsql with nice ergonomics and comptime validation.

## API sketch

### basic usage

```zig
const db = try libsql.connect("libsql://mydb.turso.io", token);

// simple query with positional args
var result = try db.query("SELECT * FROM users WHERE id = ?", .{42});
defer result.deinit();

for (result.rows()) |row| {
    const name = row.get("name", .string);
    const age = row.get("age", .int);
}
```

### named parameters

```zig
// named params - comptime validates struct fields match :placeholders
try db.exec(
    "INSERT INTO users (name, age) VALUES (:name, :age)",
    .{ .name = "bob", .age = 30 },
);

// comptime error if you typo a param name:
try db.exec(
    "INSERT INTO users (name, age) VALUES (:name, :age)",
    .{ .naem = "bob", .age = 30 },  // error: param :naem not found in SQL
);
```

### struct mapping

```zig
const User = struct {
    id: i64,
    name: []const u8,
    age: ?i64,  // nullable
};

// query directly into structs
const users = try db.queryAs(User, "SELECT id, name, age FROM users", .{});
defer users.deinit();

for (users.items) |user| {
    std.debug.print("{}: {s}, {?}\n", .{ user.id, user.name, user.age });
}

// comptime validates struct fields exist (if we parse SELECT columns)
// or runtime validation against response column names
```

### transactions

```zig
// turso pipeline API supports batched statements
try db.transaction(.{}, struct {
    fn run(tx: *Transaction) !void {
        try tx.exec("INSERT INTO users (name) VALUES (?)", .{"alice"});
        try tx.exec("INSERT INTO logs (msg) VALUES (?)", .{"created alice"});
    }
}.run);
// auto-rollback on error, auto-commit on success
```

### connection options

```zig
const db = try libsql.connect(.{
    .url = "libsql://mydb.turso.io",
    .token = token,
    .timeout_ms = 5000,
    .retry_count = 3,
});
```

## comptime features

### 1. parameter count (already have this)
```zig
db.query("SELECT * FROM users WHERE id = ?", .{1, 2});
// error: SQL has 1 placeholders but 2 args provided
```

### 2. named parameter validation
```zig
fn query(comptime sql: []const u8, args: anytype) !Result {
    comptime {
        const placeholders = parseNamedPlaceholders(sql);  // [":name", ":age"]
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

        for (placeholders) |p| {
            if (!hasField(fields, p[1..])) {  // strip leading ':'
                @compileError("param " ++ p ++ " not found in args struct");
            }
        }
    }
}
```

### 3. struct field validation (partial)
for `queryAs`, we can validate at comptime that the struct is well-formed:
- all fields are valid SQL types (i64, []const u8, ?T for nullables)
- no unsupported types

full column name validation would require either:
- parsing SELECT clause at comptime (doable but complex)
- runtime validation against response cols (simpler, still catches bugs)

### 4. SQL syntax hints (stretch goal)
basic comptime SQL parsing could catch obvious errors:
- unclosed quotes
- mismatched parens
- obviously malformed statements

not a full parser, just sanity checks.

## implementation notes

### turso HTTP API

endpoint: `POST https://{host}/v2/pipeline`

request format:
```json
{
  "requests": [
    {"type": "execute", "stmt": {"sql": "...", "args": [...]}},
    {"type": "execute", "stmt": {"sql": "...", "args": [...]}},
    {"type": "close"}
  ]
}
```

response format:
```json
{
  "results": [{
    "response": {
      "type": "execute",
      "result": {
        "cols": [{"name": "id", "decltype": "INTEGER"}, ...],
        "rows": [[1, "bob", 30], ...]
      }
    }
  }]
}
```

the `cols` array gives us column names and types at runtime - we use this for:
- named column access: `row.get("name", .string)`
- struct mapping validation
- optional runtime type checking

### arg serialization

turso args format:
```json
{"args": [
  {"type": "integer", "value": "42"},
  {"type": "text", "value": "hello"},
  {"type": "null"},
  {"type": "blob", "base64": "..."}
]}
```

we need to map zig types to these:
- `i64`, `u64`, etc → integer
- `[]const u8` → text
- `null`, `?T` when null → null
- `[]const u8` (blob flag?) → blob

### named param parsing

parse `:name` at comptime:
```zig
fn parseNamedParams(comptime sql: []const u8) []const []const u8 {
    // find all :identifier patterns
    // return slice of param names
}

fn substituteParams(comptime sql: []const u8) []const u8 {
    // replace :name with ? for the actual query
    // "WHERE id = :id" → "WHERE id = ?"
}
```

## repo structure

```
libsql-zig/
├── src/
│   ├── root.zig        # public API
│   ├── client.zig      # HTTP client, connection management
│   ├── query.zig       # query building, param substitution
│   ├── result.zig      # result parsing, row access
│   ├── types.zig       # type mapping, serialization
│   └── comptime/
│       ├── params.zig  # named param parsing
│       └── sql.zig     # SQL parsing helpers
├── build.zig
└── README.md
```

## open questions

1. **naming**: `libsql-zig`? `turso-zig`? `zsql`?

2. **local libsql support**: turso also has an embedded mode. support that too, or HTTP-only?

3. **async**: zig's async is in flux. start with blocking, add async later?

4. **allocator strategy**: arena per query? caller provides? configurable?

5. **error handling**: rich error types with SQL context, or simple error union?
