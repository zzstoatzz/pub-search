"""Pacing rules for talking to constellation.microcosm.blue.

constellation is a community-run index. The recommend reconciler used to fire
~5,000 requests per hour at it from 8 threads and swallow the 429s as "no
links", reporting success while most lookups failed (2026-09-07, reported by
the operator). These rules are the contract the script must honor:

  - a 429 is retried after the server's Retry-After (or a growing default),
    never immediately, and only a bounded number of times
  - a run where rate limiting persisted after retries is a failure, so the
    job turns red instead of quietly reconciling nothing
"""

from __future__ import annotations

from dataclasses import dataclass

MAX_ATTEMPTS = 4
DEFAULT_BACKOFF_SECONDS = (2.0, 5.0, 15.0)
MAX_BACKOFF_SECONDS = 60.0


def retry_delay(status: int, retry_after: str | None, attempt: int) -> float | None:
    """Seconds to wait before attempt+1, or None when the request must not be retried.

    `attempt` is zero-based: the first request is attempt 0.
    """
    if status != 429 or attempt >= MAX_ATTEMPTS - 1:
        return None
    if retry_after:
        try:
            return min(max(float(retry_after), 0.0), MAX_BACKOFF_SECONDS)
        except ValueError:
            pass
    idx = min(attempt, len(DEFAULT_BACKOFF_SECONDS) - 1)
    return DEFAULT_BACKOFF_SECONDS[idx]


@dataclass
class RunTally:
    requests: int = 0
    retried: int = 0
    rate_limited: int = 0
    other_errors: int = 0

    def exit_code(self) -> int:
        return 1 if self.rate_limited else 0

    def summary(self) -> str:
        return (
            f"constellation: {self.requests} requests, {self.retried} retried after 429, "
            f"{self.rate_limited} still rate-limited, {self.other_errors} other errors"
        )
