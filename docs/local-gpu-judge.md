# Local GPU judge evaluation

DeepSeek-R1-0528-Qwen3-8B Q4_K_M does not pass the current labeler gate.
On 2026-09-28, both tested thinking budgets produced the wrong majority verdict
for a hand-reviewed human illustrator. No production labels or judge settings
were changed.

## Results

The existing `scripts/judge-eval` prompt and three evidence slices per account
were used unchanged. The episode-catalog fixture had no remaining documents and
was skipped, so this covers three accounts, not the full four-account suite.

| Account | Expected | 256 thinking tokens | 1024 thinking tokens |
| --- | --- | --- | --- |
| sksksketch.net | composed | generated × 3 | generated × 2, composed × 1 |
| prideraiser.org | generated | generated × 3 | generated × 3 |
| coryd.dev | composed | composed × 2, generated × 1 | composed × 2, generated × 1 |

Both runs scored 2/3 accounts by majority. Individual votes were 5/9 and 6/9
correct respectively. The model repeatedly inferred a dataset from focused
technical tutorials and repetitive titles. More thinking improved one vote
without fixing that false positive. This result applies to this quantized model,
prompt, evidence and runtime configuration; it is not a verdict on every local
model or all DeepSeek models.

Full per-vote reasons and request times:

- [256-token budget](evals/deepseek-local-256.json): approximately 6.5–8.1 seconds per vote
- [1024-token budget](evals/deepseek-local-1024.json): approximately 9.9–14.5 seconds per vote

## Runtime

Heavypad RTX 4070 Laptop, 8 GiB VRAM; llama.cpp b11232 CUDA 12.8 build;
model SHA256 `a86349a4180c4e6bb43f874c29c404fa2be3f90b15509bd6d86f697dba724ec1`.
All model layers were offloaded. The server used one slot, 8192 context tokens,
four CPU threads, and batches/microbatches of 128. Evaluation requests used the
existing temperature 0 and max_tokens 2000 settings. Observed generation was
about 45–47 tokens/s with about 5.8 GiB VRAM used.

The temporary container bound only to heavypad's loopback, reached through SSH.
It had a ten-minute runtime cap, four-CPU/12-GiB container limits, read-only model
and runtime mounts, and an idle/pressure watchdog. Database credentials stayed
on the laptop, read from the existing encrypted store. Only evidence was sent
to the local judge; `JUDGE_API_KEY=''` prevented forwarding a provider key.

After both runs the temporary server and SSH tunnel were stopped, the container
was gone, GPU memory returned to 13 MiB, and Spindle and the home Prefect worker
remained active. No failed system or user units remained.

## Driver setup and preliminary smoke tests

Rebooting heavypad loaded NVIDIA 580.178.04 to match the installed driver
libraries, resolving the prior loaded-module mismatch. No switch to the
System76 driver package was needed. The llama.cpp b11232 CUDA executable could
not run directly on Ubuntu 22.04: `ldd` reported missing `GLIBC_2.38` and
`GLIBCXX_3.4.32`. The Ubuntu 24.04 container supplied the newer system libraries;
the wrapper mounted the host's 580.178.04 `libcuda`, PTX JIT and GPU compiler
libraries, GPU device nodes, and the downloaded CUDA 12.8 runtime bundle.
The exact wrapper and image definition are retained at
`~/.local/share/heavypad-gpu/run` and `Dockerfile` on heavypad.

The preliminary single-repeat benchmark measured 2,500 tokens/s for pp128
and 49.8 tokens/s for tg32, with four threads and batch/microbatch 128.
These short measurements are not sustained serving-throughput estimates.
The CLI trial occupied about 5.2 GiB VRAM, compared with about 5.8 GiB for the
8,192-context judge server.

The arithmetic prompt was “Calculate 17 times 19. Give the answer and one
short explanation.” Both the 512-token and 2,048-token runs stopped during
reasoning despite finding 323. With `--reasoning-budget 128`, a 512-token run
produced the correct final answer and explanation at 49.2 tokens/s. Logs are
`benchmark.log`, `prompt.log`, `prompt-complete.log`, and `prompt-budgeted.log`
in the same heavypad directory. A successful exit alone did not distinguish
completed answers from budget-exhausted reasoning.

## Reusing the evaluator

For a local OpenAI-compatible endpoint reached through an SSH tunnel:

```sh
JUDGE_PROVIDER=openai \
JUDGE_API_URL=http://127.0.0.1:18081/v1/chat/completions \
JUDGE_API_KEY='' JUDGE_CONCURRENCY=1 JUDGE_TIMEOUT=120 \
JUDGE_OUTPUT=/tmp/judge-result.json \
uv run --script scripts/judge-eval deepseek-local
```

Supply `TURSO_URL` and `TURSO_TOKEN` through the existing secret configuration.
The command does not launch a model server or emit labels. Set the server's
thinking budget explicitly and record it with the results. The model alias
`deepseek-local` refers to the model above, not a provider-hosted model.

The evaluator accepts only JSON boolean verdicts; strings and nulls remain
inconclusive. Its HTTP regression tests also verify that an empty API-key
override sends no credentials and settings errors do not display input secrets:

```sh
uv run --script scripts/tests/test_judge_eval.py
```

Before replacing the live judge, a candidate must pass every available known
account by majority. Restore a durable episode-catalog fixture and add further
held-out cases before treating a pass on this small set as deployment evidence.
