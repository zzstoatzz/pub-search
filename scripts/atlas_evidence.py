from pathlib import Path
import threading
import time

import httpx

from atlas_context import NOTES_DID, NOTES_HOST
from atlas_labels import LABELER_SUMMARY_URL, excluded_dids

TEXT_LIMIT = 3000
MAX_BATCH = 25
BASE_PATH = "COALESCE(NULLIF(d.base_path, ''), p.base_path, '')"


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


class EvidenceReader:
    def __init__(self, http: httpx.Client, turso_url: str, turso_token: str, interval: float = 1):
        self.http = http
        url = httpx.URL(turso_url.replace("libsql://", "https://", 1))
        if url.scheme != "https" or not url.host or not turso_token:
            raise ValueError("Atlas evidence requires TURSO_URL and TURSO_TOKEN")
        self.url = url.copy_with(path="/v2/pipeline")
        self.headers = {"Authorization": f"Bearer {turso_token}"}
        banned = (Path(__file__).resolve().parents[1] / "banned-dids.txt").read_text().splitlines()
        self.excluded = self.labeled_authors() | {did for line in banned if (did := line.partition("#")[0].strip())}
        self.interval = interval
        self.lock = threading.Lock()
        self.next_request = 0.0

    def labeled_authors(self) -> set[str]:
        response = self.http.get(LABELER_SUMMARY_URL)
        response.raise_for_status()
        return excluded_dids(response.json())

    def read(self, selected: list[dict], include_undiscoverable: bool = False) -> list[dict]:
        uris = list(dict.fromkeys(point["uri"] for point in selected))
        if not uris:
            return []
        if len(uris) > MAX_BATCH:
            raise ValueError("too many Atlas evidence URIs")
        if include_undiscoverable and any(not uri.startswith(f"at://{NOTES_DID}/") for uri in uris):
            raise ValueError("Atlas evidence opt-in is restricted to the notes repo")

        placeholders = ", ".join("?" for _ in uris)
        sql = f"""
            SELECT d.uri, d.did, d.rkey, d.title, d.platform, {BASE_PATH} AS base_path,
                   COALESCE(d.path, '') AS path, substr(d.content, 1, {TEXT_LIMIT}) AS content
            FROM documents d
            LEFT JOIN publications p ON p.uri = d.publication_uri
            WHERE d.uri IN ({placeholders})
              AND COALESCE(d.is_bridgyfed, 0) = 0 AND COALESCE(d.url_dead, 0) = 0
        """
        params = uris.copy()
        if include_undiscoverable:
            sql += f" AND d.did = ? AND {BASE_PATH} = ?"
            params.extend([NOTES_DID, NOTES_HOST])
        else:
            sql += f"""
              AND COALESCE(p.show_in_discover, 1) <> 0
              AND NOT EXISTS (
                SELECT 1 FROM publications hidden
                WHERE hidden.did = d.did AND hidden.base_path = {BASE_PATH}
                  AND hidden.base_path <> '' AND hidden.show_in_discover = 0
              )
            """
        body = {"requests": [
            {"type": "execute", "stmt": {"sql": sql, "args": [{"type": "text", "value": value} for value in params]}},
            {"type": "close"},
        ]}
        result = self._query(body)
        rows = {}
        for row in result["rows"]:
            uri, did, rkey, title, platform, base, path, content = (cell.get("value") for cell in row)
            if did not in self.excluded:
                rows[uri] = {"uri": uri, "title": title, "content": content,
                             "url": document_url(did, rkey, platform, base, path)}
        return [rows[uri] for uri in uris if uri in rows]

    def _query(self, body: dict) -> dict:
        with self.lock:
            for attempt in range(4):
                time.sleep(max(0, self.next_request - time.monotonic()))
                self.next_request = time.monotonic() + self.interval
                response = self.http.post(self.url, headers=self.headers, json=body)
                if response.status_code in (429, 502, 503, 504) and attempt < 3:
                    retry = response.headers.get("retry-after", "")
                    delay = min(120, int(retry)) if retry.isascii() and retry.isdigit() else 5 * 2 ** attempt
                    self.next_request = max(self.next_request, time.monotonic() + delay)
                    continue
                response.raise_for_status()
                result = response.json()["results"][0]
                if result["type"] != "ok":
                    raise ValueError("Turso rejected the Atlas evidence read")
                return result["response"]["result"]
        raise RuntimeError("unreachable evidence retry state")
