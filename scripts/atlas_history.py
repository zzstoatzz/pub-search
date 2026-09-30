from __future__ import annotations

import argparse
from contextlib import closing
from datetime import datetime, timezone
import gzip
import hashlib
import json
import sqlite3
from pathlib import Path


def archive(atlas_path: Path, database: Path) -> str:
    atlas_raw = gzip.decompress(atlas_path.read_bytes())
    atlas = json.loads(atlas_raw)
    summary_path = atlas_path.with_name("atlas-summaries.json")
    summary_raw = summary_path.read_bytes() if summary_path.exists() else b'{"status":"missing","clusters":[],"regions":[]}'
    summary = json.loads(summary_raw)
    atlas_hash = hashlib.sha256(atlas_raw).hexdigest()
    summary_hash = hashlib.sha256(summary_raw).hexdigest()
    snapshot_id = hashlib.sha256(f"{atlas_hash}:{summary_hash}".encode()).hexdigest()
    database.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(database, timeout=60)) as db, db:
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("CREATE TABLE IF NOT EXISTS objects (sha256 TEXT PRIMARY KEY, gzip BLOB NOT NULL)")
        db.execute("""CREATE TABLE IF NOT EXISTS snapshots (
            id TEXT PRIMARY KEY, archived_at TEXT NOT NULL, atlas_generated_at TEXT,
            summary_generated_at TEXT, status TEXT, clusters INTEGER, regions INTEGER,
            atlas_sha256 TEXT NOT NULL REFERENCES objects(sha256),
            summaries_sha256 TEXT NOT NULL REFERENCES objects(sha256))""")
        for digest, raw in ((atlas_hash, atlas_raw), (summary_hash, summary_raw)):
            db.execute("INSERT OR IGNORE INTO objects VALUES (?, ?)", (digest, gzip.compress(raw, mtime=0)))
        db.execute("INSERT OR IGNORE INTO snapshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (
            snapshot_id, datetime.now(timezone.utc).isoformat(), atlas["meta"].get("generatedAt"),
            summary.get("generatedAt"), summary.get("status"), len(summary.get("clusters", [])),
            len(summary.get("regions", [])), atlas_hash, summary_hash))
    return snapshot_id


def restore(database: Path, snapshot_id: str, output: Path) -> None:
    with closing(sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True)) as db:
        row = db.execute("SELECT atlas_sha256, summaries_sha256 FROM snapshots WHERE id=?", (snapshot_id,)).fetchone()
        if row is None:
            raise ValueError("unknown Atlas snapshot")
        payloads = []
        for digest in row:
            compressed = db.execute("SELECT gzip FROM objects WHERE sha256=?", (digest,)).fetchone()[0]
            raw = gzip.decompress(compressed)
            if hashlib.sha256(raw).hexdigest() != digest:
                raise ValueError("Atlas archive checksum mismatch")
            payloads.append((compressed, raw))
    output.mkdir(parents=True, exist_ok=True)
    for name, content in (("atlas.json.gz", payloads[0][0]), ("atlas-summaries.json", payloads[1][1])):
        with (output / name).open("xb") as destination:
            destination.write(content)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    save = commands.add_parser("save")
    save.add_argument("atlas", type=Path)
    export = commands.add_parser("restore")
    export.add_argument("snapshot_id")
    export.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "save":
        print(archive(args.atlas, args.database))
    else:
        restore(args.database, args.snapshot_id, args.output)
