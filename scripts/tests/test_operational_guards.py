import importlib.machinery
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from watchdog_checks import SNAPSHOT_AGE_ALERT_MINUTES, snapshot_age_minutes, snapshot_age_problem  # noqa: E402
import fly_machines  # noqa: E402


def load_guardian():
    path = SCRIPTS / "guard-snapshot-builder"
    loader = importlib.machinery.SourceFileLoader("guard_snapshot_builder", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


guardian = load_guardian()


class SnapshotAgeTests(unittest.TestCase):
    def test_threshold_is_two_hours(self):
        self.assertEqual(120, SNAPSHOT_AGE_ALERT_MINUTES)

    def test_at_threshold_is_healthy(self):
        now = 10_000.0
        self.assertIsNone(snapshot_age_problem({"build_id": "b1", "created_at": now - 120 * 60}, now))

    def test_past_threshold_names_build(self):
        now = 10_000.0
        problem = snapshot_age_problem({"build_id": "b-stale", "created_at": now - 121 * 60}, now)
        self.assertIn("121m old", problem)
        self.assertIn("b-stale", problem)

    def test_invalid_manifest_fails_closed(self):
        self.assertIn("invalid created_at", snapshot_age_problem({"build_id": "b1"}, 10_000.0))

    def test_age_helper_returns_minutes(self):
        self.assertEqual(2.0, snapshot_age_minutes({"created_at": 880.0}, 1_000.0))


class ReconcilerTests(unittest.TestCase):
    def setUp(self):
        self.serving = {
            "id": "serve",
            "name": "app",
            "state": "started",
            "config": {"env": {"FLY_PROCESS_GROUP": "app"}},
            "image_ref": {
                "registry": "registry.fly.io",
                "repository": "leaflet-search-backend",
                "tag": "deployment-new",
                "digest": "sha256:new",
            },
        }
        self.builder = {
            "id": "build",
            "name": fly_machines.BUILDER_NAME,
            "state": "stopped",
            "config": {"env": {"BUILDER_MODE": "1"}, "schedule": "hourly"},
            "image_ref": {
                "registry": "registry.fly.io",
                "repository": "leaflet-search-backend",
                "tag": "deployment-old",
                "digest": "sha256:old",
            },
        }

    def test_selects_roles_and_builds_digest_pinned_uri(self):
        machines = [self.builder, self.serving]
        self.assertEqual("build", fly_machines.select_builder(machines)["id"])
        self.assertEqual("serve", fly_machines.select_serving(machines)["id"])
        self.assertEqual(
            "registry.fly.io/leaflet-search-backend:deployment-new@sha256:new",
            fly_machines.image_uri(self.serving),
        )

    def test_ambiguous_serving_role_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "expected one started serving machine"):
            fly_machines.select_serving([self.serving, dict(self.serving)])

    def test_incomplete_image_reference_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "incomplete image_ref"):
            fly_machines.image_uri({"id": "bad", "image_ref": {"tag": "x"}})


class GuardianTests(unittest.TestCase):
    def test_starts_stopped_builder_before_page_threshold(self):
        action, _ = guardian.decide_action({"state": "stopped"}, 91, 10_000)
        self.assertEqual("start", action)

    def test_leaves_fresh_stopped_builder_alone(self):
        action, _ = guardian.decide_action({"state": "stopped"}, 89, 10_000)
        self.assertEqual("none", action)

    def test_stops_overlong_run(self):
        machine = {
            "state": "started",
            "events": [{"type": "start", "status": "started", "timestamp": 1_000_000}],
        }
        action, _ = guardian.decide_action(machine, 200, 1_000 + 51 * 60)
        self.assertEqual("stop", action)

    def test_keeps_bounded_run_alive(self):
        machine = {
            "state": "started",
            "events": [{"type": "start", "status": "started", "timestamp": 1_000_000}],
        }
        action, _ = guardian.decide_action(machine, 200, 1_000 + 49 * 60)
        self.assertEqual("none", action)


if __name__ == "__main__":
    unittest.main()
