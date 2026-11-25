from contextlib import contextmanager
from dataclasses import dataclass
import os
from pathlib import Path
import sqlite3
import threading

import httpx

from atlas_context import NOTES_DID, NOTES_HOST
from atlas_labels import LABELER_SUMMARY_URL, excluded_dids

TEXT_LIMIT = 3000
MAX_BATCH = 25


def snapshot_path() -> Path:
    return Path(os.environ["PREFECT_LOCAL_STORAGE_PATH"]).parent / "pub-search-snapshot" / "replica.db"


def document_url(did: str, rkey: str, platform: str, base: str, path: str) -> str:
    if base and not base.startswith("blento.app"):
        if path:
            return f"https://{base}/{path.removeprefix('/')}"
        if platform == "leaflet":
            return f"https://{base}/{rkey}"
    if platform == "leaflet":
        return f"https://leaflet.pub/p/{did}/{rkey}"
    if platform == "whitewind":
        return f"https://whtwnd.com/{did}/{rkey}"
    return f"https://pdsls.dev/at/{did}/site.standard.document/{rkey}"


@dataclass(frozen=True)
class Visibility:
    excluded: set[str]
    private_uris: set[str]
    private_paths: set[tuple[str, str]]

    def allows(self, did: str, publication: str, base: str, own_note: bool) -> bool:
        if did in self.excluded:
            return False
        if own_note:
            return did == NOTES_DID and base == NOTES_HOST
        return publication not in self.private_uris and (did, base) not in self.private_paths


def read_visibility(http: httpx.Client) -> Visibility:
    labels = http.get(LABELER_SUMMARY_URL)
    labels.raise_for_status()
    banned = (Path(__file__).resolve().parents[1] / "banned-dids.txt").read_text().splitlines()
    excluded = excluded_dids(labels.json()) | {did for line in banned if (did := line.partition("#")[0].strip())}

    url = httpx.URL(os.environ["TURSO_URL"].replace("libsql://", "https://", 1))
    if url.scheme != "https" or not url.host:
        raise ValueError("invalid Turso URL for Atlas visibility")
    response = http.post(
        url.copy_with(path="/v2/pipeline"),
        headers={"Authorization": f"Bearer {os.environ['TURSO_TOKEN']}"},
        json={"requests": [
            {"type": "execute", "stmt": {"sql": """
                SELECT uri, did, COALESCE(base_path, '') FROM publications
                WHERE COALESCE(show_in_discover, 1) = 0
            """}},
            {"type": "close"},
        ]},
    )
    response.raise_for_status()
    result = response.json()["results"][0]
    if result["type"] != "ok":
        raise ValueError("Turso could not supply Atlas publication visibility")
    entries = [tuple(cell["value"] for cell in row) for row in result["response"]["result"]["rows"]]
    return Visibility(excluded, {uri for uri, _, _ in entries}, {(did, base) for _, did, base in entries if base})


@contextmanager
def open_snapshot(path: Path):
    connection = sqlite3.connect(path.absolute().as_uri() + "?mode=ro&immutable=1", uri=True, check_same_thread=False)
    try:
        yield connection
    finally:
        connection.close()


class EvidenceReader:
    def __init__(self, connection: sqlite3.Connection, visibility: Visibility):
        self.connection = connection
        self.visibility = visibility
        self.lock = threading.Lock()

    def watermark(self) -> str:
        row = self.connection.execute("SELECT value FROM sync_meta WHERE key = 'source_watermark'").fetchone()
        if not row or not row[0]:
            raise ValueError("Atlas evidence snapshot has no source watermark")
        return row[0]

    def read(self, selected: list[dict], include_undiscoverable: bool = False) -> list[dict]:
        uris = list(dict.fromkeys(point["uri"] for point in selected))
        if not uris:
            return []
        if len(uris) > MAX_BATCH:
            raise ValueError("too many Atlas evidence URIs")
        if include_undiscoverable and any(not uri.startswith(f"at://{NOTES_DID}/") for uri in uris):
            raise ValueError("Atlas evidence opt-in is restricted to the notes repo")

        placeholders = ", ".join("?" for _ in uris)
        with self.lock:
            records = self.connection.execute(f"""
                SELECT d.uri, d.did, d.rkey, d.title, d.platform,
                       COALESCE(NULLIF(d.base_path, ''), p.base_path, ''),
                       COALESCE(d.path, ''), COALESCE(d.publication_uri, ''),
                       substr(d.content, 1, {TEXT_LIMIT})
                FROM documents d
                LEFT JOIN publications p ON p.uri = d.publication_uri
                WHERE d.uri IN ({placeholders})
                  AND COALESCE(d.is_bridgyfed, 0) = 0 AND COALESCE(d.url_dead, 0) = 0
            """, uris).fetchall()

        rows = {}
        for uri, did, rkey, title, platform, base, path, publication, content in records:
            policy_key = (did, publication, base, include_undiscoverable)
            if self.visibility.allows(*policy_key):
                rows[uri] = {"uri": uri, "title": title, "content": content, "policyKey": policy_key,
                             "url": document_url(did, rkey, platform, base, path)}
        return [rows[uri] for uri in uris if uri in rows]
