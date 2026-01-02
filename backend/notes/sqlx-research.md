# sqlx research notes

## what sqlx (rust) does

1. **compile-time query validation** via procedural macros
   - `query!("SELECT * FROM users WHERE id = $1", user_id)`
   - at compile time, connects to DATABASE_URL and runs `PREPARE`
   - validates: syntax, column existence, parameter types
   - returns anonymous struct with typed fields matching columns

2. **offline mode** for CI/builds without DB
   - `cargo sqlx prepare` connects to DB, caches query metadata to `.sqlx/`
   - cached JSON files contain: query hash, column names, column types, param types
   - at compile time, macro reads from cache instead of live DB
   - `cargo sqlx prepare --check` validates cache is up-to-date

3. **query_as!** for named structs
   ```rust
   struct User { id: i64, name: String }
   let users = sqlx::query_as!(User, "SELECT id, name FROM users").fetch_all(&pool).await?;
   ```

## what zig-sqlite does

1. **comptime parameter count checking**
   - parses SQL string at comptime to count `?` markers
   - validates args tuple length matches
   - compile error if mismatch

2. **optional type annotations** via custom syntax
   ```zig
   db.prepare("SELECT * FROM users WHERE age > ?{usize}")
   ```
   - the `{usize}` is parsed at comptime
   - validates that bound value is correct type
   - compile error if type mismatch

3. **no schema validation** - doesn't connect to DB at compile time

## our current situation

- turso HTTP API (not local sqlite)
- no compile-time checking at all
- manual JSON building in `turso.zig`
- manual response parsing in `result.zig`
- column access by index: `row.text(0)`, `row.int(1)`

## what we could build

### option A: comptime parameter checking (easy)

add to turso.zig:
```zig
pub fn query(comptime sql: []const u8, args: anytype) !Result {
    comptime {
        const expected = countPlaceholders(sql);
        const provided = @typeInfo(@TypeOf(args)).Struct.fields.len;
        if (expected != provided) {
            @compileError("wrong number of parameters");
        }
    }
    // ... existing code
}
```

pros:
- catches "wrong number of args" at compile time
- minimal effort
- no external dependencies

cons:
- doesn't validate types
- doesn't validate SQL syntax
- doesn't validate column existence

### option B: comptime type annotations (medium)

custom syntax like zig-sqlite:
```zig
client.query(
    "SELECT * FROM users WHERE age > ?{i64} AND name = ?{text}",
    .{ age, name }
)
```

parse `?{type}` at comptime, validate args match.

pros:
- type safety for parameters
- self-documenting queries

cons:
- non-standard SQL
- still no schema validation

### option C: offline mode like sqlx (hard)

1. write CLI tool that:
   - connects to turso
   - finds all queries in codebase (grep for `client.query`)
   - runs each query with `EXPLAIN` or similar
   - caches column info to `sqlx-cache.json`

2. at comptime, read cache and generate typed result structs

pros:
- full type safety for results
- validates against real schema

cons:
- requires CLI tool
- need to re-run on schema changes
- turso's HTTP API might not expose enough metadata
- significant complexity

### option D: named parameters (easy ergonomic win)

instead of:
```zig
client.query("SELECT * FROM users WHERE id = ? AND age > ?", &.{id, age})
```

allow:
```zig
client.query("SELECT * FROM users WHERE id = :id AND age > :age", .{ .id = id, .age = age })
```

at comptime, parse `:name` markers and match to struct field names.

pros:
- more readable
- self-documenting
- catches typos at compile time

cons:
- non-standard SQL (but common pattern)

## recommendation

start with A + D:
1. comptime parameter count checking
2. named parameters with `:name` syntax

these give us:
- compile-time error for wrong arg count
- compile-time error for misnamed parameters
- more readable queries
- minimal implementation effort

then evaluate if we need B or C based on pain points.

## turso API notes

turso HTTP API (`/v2/pipeline`) returns:
```json
{
  "results": [{
    "response": {
      "type": "execute",
      "result": {
        "cols": [{"name": "id", "decltype": "INTEGER"}, ...],
        "rows": [[1], [2], ...]
      }
    }
  }]
}
```

the `cols` array has column metadata! we could potentially:
- cache this on first query execution
- use for runtime column name lookup
- or fetch at build time for comptime generation

## implementation status

### option A: comptime parameter count checking ✓

implemented in `turso.zig`:

```zig
pub fn query(self: *Client, comptime sql: []const u8, args: anytype) !Result {
    const expected = comptime countPlaceholders(sql);
    const provided = comptime countArgsType(@TypeOf(args));
    if (expected != provided) {
        @compileError(std.fmt.comptimePrint(
            "SQL has {} placeholders but {} args provided",
            .{ expected, provided },
        ));
    }
    // ...
}
```

this gives compile-time errors like:
```
error: SQL has 1 placeholders but 2 args provided
```

### next steps

1. ~~implement option A (parameter count checking)~~ ✓
2. implement option D (named parameters) - if needed
3. evaluate if we need more based on pain points
