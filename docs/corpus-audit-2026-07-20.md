# Corpus reconciliation audit — 2026-07-20

## Verdict

The corpus is not reconciled. The serving snapshot is healthy and vectors are nearly
complete for rows that exist in Turso, but Turso itself is neither a complete nor a
fully current projection of the authoritative PDS records.

The main defect is architectural: the reconciler only checks whether indexed records
still exist. It does not enumerate current repo records, backfill records missing from
Turso, or refresh changed records. Its configured throughput is also too low to meet
its seven-day re-verification target at the current corpus size.

## Scope and method

The audit tool is `scripts/audit-corpus`. It is read-only with respect to production
systems and is resumable through a local SQLite checkpoint.

It:

1. Enumerated every `site.standard.document` repo advertised by the relay.
2. Added `site.standard.document` repos present only in Turso.
3. Resolved each DID to its current PDS and applied the current banned/Bridgy policy.
4. Called authoritative `com.atproto.repo.listRecords` for every reachable,
   policy-eligible repo and applied the current extractor eligibility rules.
5. Imported every Turso document, every document in the adopted local snapshot, and
   the complete Turbopuffer namespace.
6. Compared source, Turso, snapshot, and vector layers by URI and by the indexer's
   current content/canonical deduplication semantics.

The audit universe contained 10,546 repos: 10,542 from the relay and four found only
in Turso. Of these, 3,519 were policy-eligible, 7,024 were Bridgy-hosted, and three
were banned. Authoritative enumeration completed for 3,400 repos. Ninety-eight repos
were definitively gone and 14 PDS endpoints remained unreachable after four attempts;
those 14 are explicitly unresolved, not guessed current or stale.

Generated artifacts:

- `/tmp/pub-search-corpus-audit.sqlite`
- `/tmp/pub-search-corpus-audit.json`

## Source-to-index completeness

The reachable source corpus contained 78,369 active records:

| Source classification | Records |
| --- | ---: |
| Extractable under the current rules | 72,173 |
| Metadata-only (no body content) | 6,150 |
| Missing title | 46 |

For the 72,173 extractable records:

| Turso representation | Records | Share |
| --- | ---: | ---: |
| Exact URI present | 48,413 | 67.08% |
| Represented by valid content/canonical/cross-collection dedupe | 8,586 | 11.90% |
| Genuinely absent | 15,174 | 21.03% |
| Total represented | 56,999 | 78.97% |

The earlier suspected losses named “I Love Patina” and “O Canada” are not semantic
losses: identical title and content from the same author are present under other
source URIs. They belong to the valid dedupe bucket.

The 15,174 genuine misses are concentrated in 428 repos. The largest five account
for 9,755 records (64.3%); 22 repos have at least 100 misses. This is primarily a
historical backfill gap, not widespread recent event loss: 11,751 have a reported
publication date before 2025 or no usable date, while only 33 report a July 2026
date. No genuine miss reports a publication date on or after July 18. Publication
dates are record data, not proof of commit or ingestion time.

The five largest gaps are:

| DID | Missing | Live source records |
| --- | ---: | ---: |
| `did:plc:vd3vzujxkxsthkswrc2zzupm` | 4,785 | 5,607 |
| `did:plc:esvvys4mvoclui34shb23l5w` | 1,679 | 3,062 |
| `did:plc:e24okfpxr7ctcbmruijop5gp` | 1,493 | 8,320 |
| `did:plc:ibzvsahcpkzxbdcw4jrr2kzq` | 1,044 | 1,269 |
| `did:plc:c23vj3dsjs5whu4fs5g4zltd` | 754 | 759 |

These records must not be blindly inserted. The autonomous bulk classifier has only
six labeled authors and most large missing repos are still in its observing state,
because it has mainly observed the already-indexed subset. One currently labeled
bulk-generated author has 180 genuine misses and should remain excluded. The second
largest missing repo is explicitly classified human/personal-journal. A backfill must
run the same policy decision over the complete source inventory before publication.

## Metadata-only records

Current ingestion drops records without body content. Of the 6,150 live metadata-only
records, 5,993 are absent and 157 remain indexed from an earlier state. Because this
product links to publishers instead of rendering article bodies, rejecting a record
that has a searchable title and destination is the wrong product boundary. Standard
Reader indexes title/description/tags for these records; matching that corpus behavior
does not require integrating with it or rendering content.

Metadata-only inclusion should be implemented as a deliberate search-document type,
with no vector requirement and with ranking safeguards for thin records.

## Indexed-row correctness and deletion drift

Among repos that were authoritatively enumerated, Turso contains 1,041
`site.standard.document` rows that are no longer in the source repo. It also disagrees
with current source data on 14 titles, 394 paths, and 219 publication URIs. Therefore
reconciliation must handle create, update, and delete; existence-only checks cannot
make the read model correct.

One Bridgy-hosted row remains in Turso and the adopted snapshot despite the current
policy:

`at://did:plc:cn4qh2ejelgonebps7xk67kd/site.standard.document/3mhgme3y35c25`

The current unresolved-DID branch stamps `verified_at` and retains the row. That makes
deactivated or no-longer-resolving identities permanently look verified. For example,
Turso has 245 rows for `did:web:notiz.blog`, whose DID document no longer resolves.
Ambiguous failures should remain quarantined and retryable, not be marked verified.

The throughput target is mathematically impossible with current defaults. Fifty rows
every 30 minutes is 2,400 rows/day, so 53,699 rows require about 22.4 days for one
pass. At audit time, 6,278 rows had never been verified and 42,475 verified rows were
older than seven days. The documentation's 7–8 day estimate assumes the old ~18,000
row corpus.

## Snapshot and vectors

The adopted snapshot is healthy: it contains 53,681 documents, exactly 18 behind
Turso's 53,699, with no snapshot-only rows. This is ordinary snapshot lag, not corpus
reconciliation failure.

Turbopuffer contains 49,868 vectors. Applying the embedder's real predicate (body
length over 50 and non-test title), five Turso rows lack vectors. All five already have
`embedded_at`, so they cannot self-heal. One is the stale Bridgy row identified above
and should be deleted; the other four should be re-enqueued. Conversely, 133 vectors
across 46 authors have no Turso row and should be deleted. The raw difference between
document and vector counts is otherwise intentional.

## Required repair, in order

1. **Build a repo-level three-way reconciler.** Enumerate each repo's current records,
   extract them with the production extractor, and compare them with Turso. Emit
   explicit create, update, and delete work. Store source CID (or an equivalent stable
   content fingerprint) so unchanged rows are cheap to recognize.
2. **Separate discovery from publication.** Write a durable reconciliation run and
   item ledger containing source URI/CID, classification, intended action, policy
   decision, attempts, and terminal outcome. Dry-run summaries and per-repo caps are
   mandatory before applying historical backfills.
3. **Make backfill policy complete.** Feed the full discovered corpus into bulk-author
   classification, preserve bans and overrides, review the highest-volume observing
   repos, and exclude labeled bulk authors before their missing records can enter
   search.
4. **Add metadata-only link records.** Index title, description/tags, author, and
   destination without storing/rendering body content or requesting embeddings. Give
   thin records an explicit ranking penalty.
5. **Fix verification scheduling.** Reconcile by repo rather than row, do not stamp
   ambiguous DID/PDS failures as verified, track unreachable/gone/quarantined states,
   and size throughput to the actual corpus and freshness SLO.
6. **Repair derived layers after Turso converges.** Re-enqueue the four legitimate
   falsely marked embedded rows, delete the stale Bridgy row and 133 orphan vectors,
   build a fresh staging snapshot, run count/FTS/integrity gates, then promote it.
7. **Continuously measure invariants.** Publish source-eligible, represented, missing,
   stale, changed, snapshot-lag, vector-missing, vector-orphan, and oldest-verification
   metrics. Alert on age and ratios, not only raw totals.

The safe first implementation is the ledger-backed dry-run reconciler. The repair
should not begin with ad hoc inserts: the audit proves that completeness, author
policy, update semantics, and deletion semantics have to converge together.

## Dry-run reconciliation ledger

The first repair phase is implemented by `scripts/reconcile-corpus`. It consumes this
audit's immutable SQLite checkpoint and writes a separate durable action ledger. It
has no apply mode and cannot mutate production.

Run `audit-2026-07-20-v1` (ledger schema v1, audit sha256
`c26fd8dc3ef8f9c63e90a8f79d73032fa23622dde3ca5d5e1012e1c3d2c5e30d`) produced:

| Proposed action | Policy outcome | Records |
| --- | --- | ---: |
| Create | review required | 14,981 |
| Create | existing bulk-generated label excludes | 180 |
| Create | terminal classifier allow, below per-repo cap | 13 |
| Update | allowed | 413 |
| Verify/source-CID baseline | review required | 48,000 |
| Delete: source record absent | allowed | 1,041 |
| Delete: source repo definitively gone | allowed | 428 |
| Delete: Bridgy policy | allowed | 1 |
| Quarantine: unresolved source identity | quarantined | 288 |
| Skip: valid dedupe | preserved | 8,586 |
| Skip: metadata-only or missing title | feature/review pending | 6,196 |

Six repos exceed the default 250-create cap. Even a terminal classifier allow does
not bypass this cap: the 1,679-record personal-journal repo remains review-gated.

The canary was the sole proposed create for
`did:plc:ztjsajckkmfscs3tshez4ath`. A fresh `getRecord` returned the same source CID
recorded in the ledger, while the adopted serving snapshot returned zero rows for the
URI. No record was applied.

Before apply mode can exist, production documents need a persisted source CID (or an
equivalent extractor-versioned fingerprint), each item must be revalidated against
its current source CID immediately before mutation, creates must pass complete-source
classifier policy, and delete/create replacement groups must be applied atomically
enough that URI churn cannot temporarily erase a publication.
