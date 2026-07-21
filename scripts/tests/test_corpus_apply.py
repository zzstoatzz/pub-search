import datetime as dt
import hashlib
from pathlib import Path
import runpy
import sqlite3
import sys
import tempfile
import types
import unittest


if "httpx" not in sys.modules:
    try:
        __import__("httpx")
    except ModuleNotFoundError:
        # CI's stdlib-only operational-guard job tests the ledger logic; HTTP
        # integration runs through the script's uv-managed environment.
        sys.modules["httpx"] = types.ModuleType("httpx")

APPLY = runpy.run_path(str(Path(__file__).parents[1] / "apply-corpus-reconciliation"))


class CorpusApplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.audit = root / "audit.sqlite"
        self.audit.write_bytes(b"immutable audit")
        self.ledger_path = root / "ledger.sqlite"
        self.db = APPLY["open_ledger"](self.ledger_path)
        self.db.executescript(
            """
            CREATE TABLE runs (
              run_id TEXT PRIMARY KEY,status TEXT,audit_db TEXT,audit_sha256 TEXT,
              audit_inventory_at TEXT
            );
            CREATE TABLE repo_plans (
              run_id TEXT,did TEXT,pds TEXT,source_status TEXT,source_policy TEXT,
              classifier_state TEXT
            );
            CREATE TABLE items (
              run_id TEXT,uri TEXT,did TEXT,source_cid TEXT,action TEXT,reason TEXT,
              policy_decision TEXT,status TEXT,attempts INTEGER DEFAULT 0,outcome TEXT,
              PRIMARY KEY(run_id,uri)
            );
            """
        )
        digest = hashlib.sha256(self.audit.read_bytes()).hexdigest()
        inventory = dt.datetime.now(dt.timezone.utc).isoformat()
        self.db.execute(
            "INSERT INTO runs VALUES ('run','complete',?,?,?)",
            (str(self.audit), digest, inventory),
        )
        self.db.execute(
            "INSERT INTO repo_plans VALUES ('run','did:plc:test','https://pds.example','complete','eligible','rejected')"
        )

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def add(self, rkey, action, decision="allow", status="proposed"):
        self.db.execute(
            "INSERT INTO items VALUES (?,?,?,?,?,?,?,?,0,NULL)",
            ("run", f"at://did:plc:test/site.standard.document/{rkey}", "did:plc:test", f"cid-{rkey}", action, "test", decision, status),
        )
        self.db.commit()

    def test_selects_only_allowed_safe_statuses_in_safe_order(self):
        self.add("delete", "delete")
        self.add("create", "create")
        self.add("update", "update")
        self.add("verify", "verify")
        self.add("review", "create", decision="review")
        self.add("done", "verify", status="applied")

        APPLY["validate_run"](self.db, "run", 1)
        rows = APPLY["selected_rows"](
            self.db, "run", ["verify", "update", "create", "delete"], None, False
        )
        self.assertEqual(["verify", "update", "create", "delete"], [row["action"] for row in rows])
        self.assertNotIn("review", [row["uri"].rsplit("/", 1)[-1] for row in rows])

    def test_retry_failed_is_explicit(self):
        self.add("failed", "update", status="failed")
        self.assertEqual([], APPLY["selected_rows"](self.db, "run", ["update"], None, False))
        self.assertEqual(1, len(APPLY["selected_rows"](self.db, "run", ["update"], None, True)))

    def test_extracts_only_https_pds(self):
        valid = {"service": [{"type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.example/"}]}
        invalid = {"service": [{"type": "AtprotoPersonalDataServer", "serviceEndpoint": "http://pds.example"}]}
        self.assertEqual("https://pds.example", APPLY["pds_from_document"](valid))
        self.assertIsNone(APPLY["pds_from_document"](invalid))


if __name__ == "__main__":
    unittest.main()
