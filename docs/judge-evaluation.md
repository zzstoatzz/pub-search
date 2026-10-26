# Judge evaluation, 2026-10-25

Haiku 5.5 replaces Haiku 4.5 as the Anthropic judge and GPT-5.6-luna as the
production default. The original migration gate contained a wrong expected
answer: it required labeling Prideraiser's original organizer descriptions as
bulk-generated. Agreement with that answer key did not establish better judgment.

## Policy and evidence review

The policy is composed writing versus generated text, not directories versus
blogs. Original organizer descriptions, personal reviews, and diary entries
remain writing even when their titles or publishing interface use templates.
A record-shaped page alone does not establish that its text was generated.

Prideraiser's current native records contain distinct organizer descriptions.
For example, the [Rebellion 99 campaign record](https://pdsls.dev/at/did:plc:5swhfspkrynnbidlkrkch3lh/site.standard.document/3mwrmtpgg622f)
opens “At Rebellion 99, we believe supporting Angel City means supporting our
community”. Its CID at review was
`bafyreibl3ijhxv2xtxew4lz577mhiekxwpkbvoeu2dp6yruvckgpuck4wm`.
The [Die Innenstadt campaign](https://pdsls.dev/at/did:plc:5swhfspkrynnbidlkrkch3lh/site.standard.document/3mx6i47vibo2h)
describes its own local beneficiary and campaign. The three current database
slices also include dashboard announcements, campaign reviews, and organizer
narratives. A title pattern is insufficient evidence to label these bodies.
The user explicitly confirmed that original organizer writing should be kept;
the Prideraiser expected answer was corrected before changing the prompt.

A second historical assumption failed the same check: eligundry.com's repeated
“I felt …” titles wrap original diary prose about work, meals, and relationships.
Fifteen sampled bodies across three slices support keeping the account. This
case is now a regression against classifying a journal from its title template.

The expanded set includes eight real accounts:

| Account | Expected | Reason |
|---|---|---|
| sksksketch.net | keep | Original illustration/software writing |
| prideraiser.org | keep | Original organizer descriptions and announcements |
| thefestivusproject.com | label | One synopsis per episode; retained native-record sample |
| coryd.dev | keep | Original blog, including personal reviews |
| frankhecker.com | keep | Original blog backfill |
| den.dev | keep | Original software blog |
| chicagotransitalerts.app | label | Templated transit service-event feed |
| eligundry.com | keep | Original mood-journal prose |

These expectations were selected from source evidence and the stated policy,
not from which model agreed with them. Four accounts were added after the prompt
clarification, without further tuning to their model responses.

## Matched comparisons

Each account receives three phased evidence slices. Models in each comparison
receive identical saved material. Both Haiku models receive a 4096-token limit;
5.5 receives medium effort, and 4.5 receives no effort parameter. Neither receives
a sampling parameter. The final runtime uses these same 5.5 settings.

| Prompt and set | Model | Correct account majorities | Correct individual votes |
|---|---|---:|---:|
| Original prompt, corrected four-account truth | Haiku 4.5 | 3/4 | 8/12 |
| Original prompt, corrected four-account truth | Haiku 5.5 | 4/4 | 11/12 |
| Clarified prompt, expanded eight-account set | Haiku 4.5 | 7/8 | 20/24 |
| Clarified prompt, expanded eight-account set | Haiku 5.5 | 8/8 | 24/24 |
| Same expanded evidence, second run | Haiku 5.5 | 8/8 | 24/24 |
| Clarified prompt, expanded eight-account set | GPT-5.6-luna | 7/8 | 22/24 |

On the expanded comparison, 4.5 labels Prideraiser on all three slices and
incorrectly labels one slice of Cory's blog. GPT-5.6-luna labels Prideraiser
on two slices. 5.5 keeps both accounts and still labels the episode catalog and
transit feed on every slice. There is no observed advantage for 4.5 under the
reviewed policy in these runs. This is a small regression set, not a claim of
universal model superiority or a representative spam benchmark.

The original raw report retains its historical, incorrect Prideraiser `truth`
field. The first two rows above rescore its verdicts using the corrected truth.
All later reports contain the corrected expected answers.

## Cost and reproducibility

The expanded Haiku comparison reports 35,114 input / 1,571 output tokens for
4.5 and 46,040 input / 5,381 output tokens for 5.5. At published short-context
rates (4.5: $1/$5; 5.5: $0.10/$0.50 per million input/output tokens), estimated
model cost is $0.042969 versus $0.0072945: about 83% lower for 5.5 despite its
larger token count. These are rate-based estimates, not invoice charges. See
[Anthropic's model overview](https://platform.claude.com/docs/en/models/haiku-5-5/overview).

Per-vote verdicts, reasons, usage, timings, and comparison hashes are retained in
[judge-evaluation.json](judge-evaluation.json). The expanded prompt SHA-256 is
`496cd5eaf41a827f77d676754c9b41d8e01b1973641cddfeeebb7b717d987afa`;
the expanded material SHA-256 is
`98db52fc90e6e4b5a63b92d2bc04c40e09e0b72d1daae8bc23ba83bbbd3d5d67`.

The evaluator reads the same `backend/src/ingest/review_prompt.txt` embedded by
production. `JUDGE_MATERIALS` saves evidence on first use and replays an existing
file without database reads. `JUDGE_OUTPUT` saves the report. Missing accounts
or incorrect majorities return a failing exit status. Evidence extraction now
uses UTF-8 byte windows, matching the production Zig sampler.

```sh
JUDGE_PROVIDER=anthropic JUDGE_MATERIALS=/path/to/materials.json \
  JUDGE_OUTPUT=/path/to/comparison.json \
  scripts/judge-eval claude-haiku-4-5 claude-haiku-5-5
```

## Deployment verification

[Backend deployment](https://github.com/zzstoatzz/pub-search/actions/runs/40254689008)
passed for commit `b134a2e1d43238fe15ba614a320cf769e56658b2`. Both Fly machines
run that source. The app's startup log confirms
`claude-haiku-5-5 @ https://api.anthropic.com/v1/messages`; the configured API-key
hash matches the canonical Anthropic credential without exposing the value.
The health endpoint and a Prideraiser author-scoped search pass after deployment.

Prideraiser's existing `bulk-generated` label was retracted at sequence 197
(`2026-10-26T01:33:51Z`). The public label stream confirms `neg=true`; classifier
state is REJECTED with `label negated by operator`, preventing automatic
re-labeling. The mood journal's latest labels were already negated and needed
no mutation.

Local checks passed: 70 Python tests (plus four subtests), 190 backend tests
(with one existing skip), 28 Node tests, and 37 MCP tests. CI's Python and backend
checks also passed before deployment.
