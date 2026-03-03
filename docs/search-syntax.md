# search syntax

a reference for the query syntax at [pub-search.waow.tech](https://pub-search.waow.tech).

## basics

terms are OR'd together — a query matches documents containing *any* of the words. the last word gets prefix matching for a type-ahead feel.

| you type | what runs | why |
|----------|-----------|-----|
| `cat dog` | `cat OR dog*` | matches docs with "cat" or "dog" (or "dogs", "dogma", etc.) |
| `crypto` | `crypto*` | prefix match: finds "crypto", "cryptocurrency", etc. |

## quoted phrases

wrap words in double quotes for exact phrase matching — FTS5 requires the words to appear adjacent and in order.

| you type | what runs |
|----------|-----------|
| `"machine learning"` | `"machine learning"` |
| `python "machine learning" tutorial` | `python OR "machine learning" OR tutorial*` |
| `"exact phrase" python` | `"exact phrase" OR python*` |

the last token only gets a prefix `*` if it's a bare word — phrases are never prefix-expanded.

unclosed quotes are treated as phrases: `"hello world` → `"hello world"`.

## explicit OR

`OR` (uppercase, case-sensitive) between terms is recognized as an operator rather than a search term. this means you can write natural boolean queries without them getting mangled.

| you type | what runs |
|----------|-----------|
| `bertha OR burton` | `bertha OR burton*` |
| `cat OR dog OR fish` | `cat OR dog OR fish*` |

`OR` at the start or end of a query is ignored — only `OR` between terms matters.

## filters

beyond the query text, you can filter results by:

- **platform**: leaflet, pckt, offprint, greengale, whitewind, other
- **tag**: click any tag in the results to filter by it
- **date**: today, this week, this month, this year

filters combine with the search query — e.g., searching `python` with the `leaflet` platform filter returns only leaflet posts matching "python".

## search modes

three modes are available via the toggle below the search box:

- **keyword** (default): SQLite FTS5 full-text search with BM25 ranking + recency boost. fastest (~9ms).
- **semantic**: vector similarity via Voyage AI embeddings + turbopuffer. finds conceptually similar content even without shared words (~345ms).
- **hybrid**: runs both keyword and semantic in parallel, merges via reciprocal rank fusion. best quality, slightly slower (~360ms).

## ranking

keyword results are ranked by `BM25 + recency`:
- BM25 scores term frequency and document length (standard IR ranking)
- recency adds a small boost for newer documents: `rank + (days_old / 30)`

## tokenization

the FTS5 unicode61 tokenizer treats any non-alphanumeric character as a separator. this means:
- `crypto-casino` → matches "crypto" and "casino" separately
- `don't` → matches "don" and "t"
- `foo.bar` → matches "foo" and "bar"
