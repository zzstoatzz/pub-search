# pub-search

## development

Use the repository's build and test commands in [README.md](README.md).
MCP tests run with `cd pub-search-mcp/server && uv run pytest`.
Update Zig dependency hashes with `zig fetch --save <url>`.

## publishing and operations

- Push main to both Tangled `origin` and the `github` mirror. GitHub Actions
  deploys backend changes under `backend/**`.
- Frontend publishing follows [deployment](docs/deployment.md): refresh live Atlas
  datasets first and use `site/deploy.sh`, which rebuilds the service worker.
- Run Fly commands from the intended app directory; `--app` does not select its config.
- Keep the embedder worker at exactly one machine. Verify the running machine
  after scaling, not just the configured count.
- Snapshot builds belong to my-prefect-server's `pub-search-snapshot` deployment.
  Read [snapshot pipeline](docs/snapshot-pipeline.md) before building or promoting;
  production publication requires the explicit production channel gate.

## data contracts

- Turso is authoritative. The serving SQLite snapshot is immutable between
  adoptions; use [overlay serving](docs/overlay-serving.md) for live freshness.
- Query changes follow [scaling design](docs/scaling-plan.md). Use one FTS `MATCH`
  per keyword statement; generate snippets from document text in Zig.
- Migrations are append-only. Keep `BOOTSTRAP_BASELINE_COUNT` fixed at 10 and
  follow [migration procedures](docs/migrations.md).
- Judge changes require `scripts/judge-eval <model>` and correct majorities for
  every known account. Follow [judge evaluation](docs/judge-evaluation.md), reuse
  the production prompt, and preserve decided authors during rescoring.
- Preserve durable daily review budgets. Unavailable evidence must defer review
  without spending a review or increasing attempts.
- Before changing MCP packaging, check the nested installation constraint in
  [deployment](docs/deployment.md#mcp-packaging).
