from __future__ import annotations

import hashlib
import math

import httpx

NOTES_DID = "did:plc:xbtmt2zjwlrfegqvch7fboei"
NOTES_HOST = "notes.zzstoatzz.io"
MIN_COSINE = 0.75
CONTEXT_LIMIT = 3


class ContextReader:
    def __init__(self, http: httpx.Client, api_key: str, namespace: str = "leaflet-search", url: str | None = None):
        self.http = http
        self.api_key = api_key
        self.url = url or f"https://api.turbopuffer.com/v2/namespaces/{namespace}/query"

    def query(self, body: dict) -> list[dict]:
        response = self.http.post(self.url, headers={"Authorization": f"Bearer {self.api_key}"}, json=body)
        response.raise_for_status()
        return response.json()["rows"]

    def retrieve(self, evidence: list[dict], excluded_uris: set[str]) -> list[dict]:
        ids = [hashlib.sha256(e["uri"].encode()).hexdigest()[:32] for e in evidence]
        rows = self.query({"rank_by": ["id", "asc"], "top_k": len(ids),
                           "filters": ["id", "In", ids], "include_attributes": ["vector"]})
        vectors = [row["vector"] for row in rows]
        if len(vectors) < 3:
            return []
        normalized = []
        for vector in vectors:
            norm = math.sqrt(sum(x * x for x in vector))
            if not norm or not math.isfinite(norm):
                raise ValueError("invalid context seed vector")
            normalized.append([x / norm for x in vector])
        if len({len(v) for v in normalized}) != 1:
            raise ValueError("inconsistent context seed dimensions")
        centroid = [sum(values) / len(normalized) for values in zip(*normalized)]
        body = {"rank_by": ["vector", "ANN", centroid], "top_k": 12,
                "include_attributes": ["uri", "did", "base_path"]}
        candidates = self.query(body)
        candidates += self.query({**body, "filters": ["And", [["did", "Eq", NOTES_DID], ["base_path", "Eq", NOTES_HOST]]]})
        return select_context(candidates, excluded_uris)


def select_context(candidates: list[dict], excluded_uris: set[str]) -> list[dict]:
    selected = {}
    for row in candidates:
        distance = row.get("$dist")
        uri = row.get("uri", "")
        if type(distance) not in (int, float) or not math.isfinite(distance) or not 0 <= distance <= 1 - MIN_COSINE:
            continue
        if not uri.startswith("at://") or uri in excluded_uris:
            continue
        item = {"uri": uri, "cosineSimilarity": 1 - distance,
                "includeUndiscoverable": row.get("did") == NOTES_DID and row.get("base_path") == NOTES_HOST}
        if uri not in selected or item["cosineSimilarity"] > selected[uri]["cosineSimilarity"]:
            selected[uri] = item
    return sorted(selected.values(), key=lambda p: (-p["cosineSimilarity"], p["uri"]))[:CONTEXT_LIMIT]


def is_owned_note(point: dict) -> bool:
    return point.get("uri", "").startswith(f"at://{NOTES_DID}/") and point.get("basePath") == NOTES_HOST
