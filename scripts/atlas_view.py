"""The Atlas page's download: atlas.json.gz re-laid as columns.

Same documents, clusters and publications, about half the bytes. Points are
grouped by uri so one author's titles and paths sit together for gzip, and
`index` restores the map's original order. site/atlas-view.js decodes it back
to the atlas.json shape; atlas.json.gz stays the canonical build output.
"""
from __future__ import annotations

import argparse
from collections import Counter
import gzip
import json
from pathlib import Path

VERSION = 1
NAME = "atlas-view.json.gz"
# stands in for the record key where a path repeats it
RKEY = "\x01"


def table(values: list[str]) -> tuple[list[str], list[int]]:
    names = [name for name, _ in Counter(values).most_common()]
    position = {name: i for i, name in enumerate(names)}
    return names, [position[value] for value in values]


def encode(atlas: dict) -> dict:
    points = atlas["points"]
    order = sorted(range(len(points)), key=lambda i: points[i]["uri"])
    rows = [points[i] for i in order]
    parts = []
    for row in rows:
        if not row["uri"].startswith("at://") or RKEY in row["path"]:
            raise ValueError(f"cannot encode {row['uri']}")
        did, collection, rkey = row["uri"][5:].split("/", 2)
        parts.append((did, collection, rkey))
    dids, did = table([part[0] for part in parts])
    collections, collection = table([part[1] for part in parts])
    base_paths, base_path = table([row["basePath"] for row in rows])
    platforms, platform = table([row["platform"] for row in rows])
    for row in rows:
        if round(row["x"], 4) != row["x"] or round(row["y"], 4) != row["y"]:
            raise ValueError(f"coordinates of {row['uri']} have more than 4 decimals")
    return {
        "version": VERSION,
        "meta": atlas["meta"],
        "clusters": atlas["clusters"],
        "publications": atlas["publications"],
        "platforms": platforms,
        "dids": dids,
        "collections": collections,
        "basePaths": base_paths,
        "points": {
            "index": order,
            "x": [round(row["x"] * 10000) for row in rows],
            "y": [round(row["y"] * 10000) for row in rows],
            "platform": platform,
            "did": did,
            "collection": collection,
            "rkey": [part[2] for part in parts],
            "basePath": base_path,
            "title": [row["title"] for row in rows],
            "path": [row["path"].replace(part[2], RKEY) if part[2] else row["path"] for row, part in zip(rows, parts)],
            "clusterCoarse": [row["clusterCoarse"] for row in rows],
            "clusterFine": [row["clusterFine"] for row in rows],
        },
    }


def decode(view: dict) -> dict:
    """Reference inverse of encode; the page's copy is site/atlas-view.js."""
    if view.get("version") != VERSION:
        raise ValueError("unknown Atlas view version")
    columns = view["points"]
    points: list[dict | None] = [None] * len(columns["index"])
    for k, i in enumerate(columns["index"]):
        rkey = columns["rkey"][k]
        points[i] = {
            "x": columns["x"][k] / 10000,
            "y": columns["y"][k] / 10000,
            "uri": f"at://{view['dids'][columns['did'][k]]}/{view['collections'][columns['collection'][k]]}/{rkey}",
            "title": columns["title"][k],
            "platform": view["platforms"][columns["platform"][k]],
            "basePath": view["basePaths"][columns["basePath"][k]],
            "path": columns["path"][k].replace(RKEY, rkey),
            "clusterCoarse": columns["clusterCoarse"][k],
            "clusterFine": columns["clusterFine"][k],
        }
    return {"points": points, "clusters": view["clusters"], "publications": view["publications"], "meta": view["meta"]}


def write(atlas_path: Path) -> Path:
    atlas = json.loads(gzip.decompress(atlas_path.read_bytes()))
    output = atlas_path.with_name(NAME)
    raw = json.dumps(encode(atlas), ensure_ascii=False, separators=(",", ":")).encode()
    output.write_bytes(gzip.compress(raw, mtime=0))
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("atlas", type=Path)
    path = write(parser.parse_args().atlas)
    print(f"{path.name}: {path.stat().st_size / 1024:.0f} KB")
