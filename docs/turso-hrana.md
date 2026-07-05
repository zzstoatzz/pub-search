# turso and hrana

pub-search uses [Turso](https://turso.tech) (hosted libsql) via the HTTP API.

## what is hrana?

hrana (czech for "edge") is the protocol for connecting to libsql/sqlite over the network. designed for edge functions where low latency matters.

the HTTP API (`/v2/pipeline`) is "hrana over HTTP" - stateless version of the websocket protocol.

## request format

```json
{
  "requests": [
    {
      "type": "execute",
      "stmt": {
        "sql": "SELECT * FROM users WHERE id = ?",
        "args": [
          { "type": "text", "value": "123" }
        ]
      }
    },
    { "type": "close" }
  ]
}
```

### stmt fields

| field | type | required | notes |
|-------|------|----------|-------|
| sql | string | yes | single SQL statement |
| args | array | no | positional parameters, **omit if empty** |
| named_args | array | no | named parameters (`:name`, `@name`, `$name`) |
| want_rows | bool | no | default true, set false to skip row data |

### value types

```typescript
type Value =
  | { "type": "null" }
  | { "type": "integer", "value": string }  // string to avoid precision loss
  | { "type": "float", "value": number }
  | { "type": "text", "value": string }
  | { "type": "blob", "base64": string }
```

## response format

```json
{
  "baton": null,
  "base_url": null,
  "results": [
    {
      "type": "ok",
      "response": {
        "type": "execute",
        "result": {
          "cols": [{"name": "id", "decltype": "TEXT"}],
          "rows": [["123"]],
          "affected_row_count": 0,
          "last_insert_rowid": null
        }
      }
    },
    { "type": "ok", "response": { "type": "close" } }
  ]
}
```

## gotchas

1. **args must be omitted, not null** - `"args": null` is invalid, omit the field entirely when no args
2. **integers as strings** - large integers are strings in JSON to preserve precision
3. **always close** - include `{"type": "close"}` at the end of requests array

## references

- [Turso HTTP API docs](https://docs.turso.tech/sdk/http/reference)
- [Hrana 3 spec](https://github.com/tursodatabase/libsql/blob/main/docs/HRANA_3_SPEC.md)
- [HTTP v2 spec](https://github.com/tursodatabase/libsql/blob/main/docs/HTTP_V2_SPEC.md)
