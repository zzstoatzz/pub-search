import importlib.machinery
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


def load_reconciler():
    path = SCRIPTS / "reconcile-corpus"
    loader = importlib.machinery.SourceFileLoader("reconcile_corpus", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


reconciler = load_reconciler()


def audit_fixture(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.executescript(
        """
        CREATE TABLE repos (
          did TEXT PRIMARY KEY, in_relay INTEGER, pds TEXT, resolution_status TEXT,
          policy TEXT, audit_status TEXT, source_count INTEGER, error TEXT
        );
        CREATE TABLE source_documents (
          uri TEXT PRIMARY KEY, did TEXT, rkey TEXT, cid TEXT, title TEXT,
          publication_uri TEXT, path TEXT, published_at TEXT, eligibility TEXT,
          content_fingerprint TEXT
        );
        CREATE TABLE turso_documents (
          uri TEXT PRIMARY KEY, did TEXT, rkey TEXT, title TEXT, content_length INTEGER,
          created_at TEXT, publication_uri TEXT, path TEXT, platform TEXT,
          source_collection TEXT, indexed_at TEXT, embedded_at TEXT, verified_at TEXT,
          is_bridgyfed INTEGER, url_dead INTEGER
        );
        """
    )
    return db


def source(uri, did, rkey, title="title", eligibility="eligible", fingerprint=None, path="/p"):
    return (uri, did, rkey, "cid-" + rkey, title, "at://pub", path, None, eligibility, fingerprint)


def target(uri, did, rkey, title="title", path="/p", collection="site.standard.document"):
    return (uri, did, rkey, title, 100, None, "at://pub", path, "other", collection, None, None, None, 0, 0)


class CorpusReconcileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.audit = audit_fixture(root / "audit.sqlite")
        self.ledger = reconciler.connect_ledger(root / "ledger.sqlite")
        self.run_id = "test-run"
        self.ledger.execute(
            """INSERT INTO runs
               (run_id,schema_version,status,created_at,audit_db,audit_sha256,create_cap)
               VALUES (?,?,?,?,?,?,?)""",
            (self.run_id, 1, "planning", "now", "audit", "sha", 1),
        )

    def tearDown(self):
        self.audit.close()
        self.ledger.close()
        self.tmp.cleanup()

    def add_repo(self, did, policy="eligible", status="complete"):
        self.audit.execute(
            "INSERT INTO repos VALUES (?,?,?,?,?,?,?,?)",
            (did, 1, "https://pds.test", "resolved", policy, status, 0, None),
        )

    def plan(self, did, classifier=None, cap=1):
        repo = self.audit.execute("SELECT * FROM repos WHERE did=?", (did,)).fetchone()
        reconciler.plan_repo(self.ledger, self.audit, self.run_id, repo, classifier or {}, set(), cap)

    def test_complete_repo_emits_explicit_actions_and_preserves_dedupes(self):
        did = "did:plc:complete"
        self.add_repo(did)
        sources = [
            source("at://complete/doc/same", did, "same", fingerprint="fp-same"),
            source("at://complete/doc/changed", did, "changed", title="new"),
            source("at://complete/doc/new1", did, "new1", fingerprint="fp-new1", path="/new1"),
            source("at://complete/doc/new2", did, "new2", fingerprint="fp-new2", path="/new2"),
            source("at://complete/doc/meta", did, "meta", eligibility="no_content"),
            source("at://complete/doc/dupe", did, "dupe", fingerprint="fp-same", path="/dupe"),
        ]
        targets = [
            target("at://complete/doc/same", did, "same"),
            target("at://complete/doc/changed", did, "changed", title="old"),
            target("at://complete/doc/stale", did, "stale"),
        ]
        self.audit.executemany("INSERT INTO source_documents VALUES (?,?,?,?,?,?,?,?,?,?)", sources)
        self.audit.executemany("INSERT INTO turso_documents VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", targets)
        self.plan(did, cap=1)

        actions = {
            row["uri"]: (row["action"], row["reason"], row["policy_decision"])
            for row in self.ledger.execute("SELECT * FROM items WHERE run_id=?", (self.run_id,))
        }
        self.assertEqual(("verify", "target_has_no_source_cid", "review"), actions["at://complete/doc/same"])
        self.assertEqual(("update", "fields_changed:title", "allow"), actions["at://complete/doc/changed"])
        self.assertEqual(("skip", "content_duplicate_present", "allow"), actions["at://complete/doc/dupe"])
        self.assertEqual(("skip", "metadata_only_pending", "review"), actions["at://complete/doc/meta"])
        self.assertEqual(("delete", "source_record_absent", "allow"), actions["at://complete/doc/stale"])
        self.assertEqual("review", actions["at://complete/doc/new1"][2])
        self.assertEqual("review", actions["at://complete/doc/new2"][2])
        plan = self.ledger.execute("SELECT * FROM repo_plans WHERE did=?", (did,)).fetchone()
        self.assertEqual(1, plan["create_cap_exceeded"])
        self.assertEqual("review", plan["decision"])

    def test_classifier_label_excludes_create_but_kept_or_rejected_can_pass(self):
        for suffix, state in (("labeled", 2), ("rejected", 3)):
            did = "did:plc:" + suffix
            self.add_repo(did)
            self.audit.execute(
                "INSERT INTO source_documents VALUES (?,?,?,?,?,?,?,?,?,?)",
                source(f"at://{suffix}/doc/new", did, "new"),
            )
            self.plan(did, {did: {"did": did, "state": state, "doc_count": 10, "reason": "test"}})
        decisions = {
            row["did"]: row["policy_decision"]
            for row in self.ledger.execute("SELECT did,policy_decision FROM items WHERE action='create'")
        }
        self.assertEqual("exclude", decisions["did:plc:labeled"])
        self.assertEqual("allow", decisions["did:plc:rejected"])

    def test_create_cap_never_weakens_an_exclusion(self):
        did = "did:plc:labeled-large"
        self.add_repo(did)
        for index in range(2):
            self.audit.execute(
                "INSERT INTO source_documents VALUES (?,?,?,?,?,?,?,?,?,?)",
                source(f"at://labeled-large/doc/{index}", did, str(index), path=f"/{index}"),
            )
        self.plan(did, {did: {"did": did, "state": 2, "doc_count": 2, "reason": "test"}}, cap=1)
        decisions = {
            row[0] for row in self.ledger.execute(
                "SELECT policy_decision FROM items WHERE did=? AND action='create'", (did,)
            )
        }
        self.assertEqual({"exclude"}, decisions)

    def test_policy_exclusion_deletes_but_ambiguous_source_is_quarantined(self):
        bridgy = "did:plc:bridgy"
        unresolved = "did:plc:unresolved"
        self.add_repo(bridgy, policy="bridgy", status="policy_excluded")
        self.add_repo(unresolved, status="error")
        self.audit.execute("INSERT INTO turso_documents VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", target("at://bridgy/doc/1", bridgy, "1"))
        self.audit.execute("INSERT INTO turso_documents VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", target("at://unresolved/doc/1", unresolved, "1"))
        self.plan(bridgy)
        self.plan(unresolved)
        rows = {
            row["did"]: (row["action"], row["policy_decision"])
            for row in self.ledger.execute("SELECT did,action,policy_decision FROM items")
        }
        self.assertEqual(("delete", "allow"), rows[bridgy])
        self.assertEqual(("quarantine", "quarantine"), rows[unresolved])


if __name__ == "__main__":
    unittest.main()
