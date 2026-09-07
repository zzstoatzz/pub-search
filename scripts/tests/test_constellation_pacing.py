import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from constellation_pacing import (  # noqa: E402
    DEFAULT_BACKOFF_SECONDS,
    MAX_ATTEMPTS,
    MAX_BACKOFF_SECONDS,
    RunTally,
    retry_delay,
)


class RetryDelayTests(unittest.TestCase):
    def test_429_honors_retry_after(self):
        self.assertEqual(7.0, retry_delay(429, "7", 0))

    def test_retry_after_is_capped(self):
        self.assertEqual(MAX_BACKOFF_SECONDS, retry_delay(429, "3600", 0))

    def test_429_without_header_backs_off_and_grows(self):
        delays = [retry_delay(429, None, a) for a in range(MAX_ATTEMPTS - 1)]
        self.assertEqual(list(DEFAULT_BACKOFF_SECONDS[: len(delays)]), delays)
        self.assertEqual(sorted(delays), delays)
        self.assertTrue(all(d > 0 for d in delays))

    def test_unparseable_retry_after_falls_back_to_default(self):
        self.assertEqual(DEFAULT_BACKOFF_SECONDS[0], retry_delay(429, "soon", 0))

    def test_429_is_not_retried_forever(self):
        self.assertIsNone(retry_delay(429, "1", MAX_ATTEMPTS - 1))

    def test_non_429_is_not_retried(self):
        for status in (200, 400, 404, 500, 502):
            self.assertIsNone(retry_delay(status, "1", 0), status)


class RunTallyTests(unittest.TestCase):
    def test_persistent_rate_limiting_fails_the_run(self):
        # the pre-fix behaviour: thousands of 429s and exit 0
        self.assertEqual(1, RunTally(requests=5000, rate_limited=4400).exit_code())

    def test_retries_that_recovered_do_not_fail_the_run(self):
        self.assertEqual(0, RunTally(requests=100, retried=12).exit_code())

    def test_summary_names_every_counter(self):
        s = RunTally(requests=3, retried=2, rate_limited=1, other_errors=0).summary()
        for n in ("3 requests", "2 retried", "1 still rate-limited", "0 other errors"):
            self.assertIn(n, s)


if __name__ == "__main__":
    unittest.main()
