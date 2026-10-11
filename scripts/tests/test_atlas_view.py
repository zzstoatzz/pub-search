import gzip
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import atlas_view


def atlas():
    points = [
        {"x": 0.1349, "y": -0.0048, "uri": "at://did:plc:b/site.standard.document/3mrkey", "title": "Café — notes",
         "platform": "leaflet", "basePath": "b.example", "path": "/3mrkey", "clusterCoarse": -1, "clusterFine": 7,
         "membershipProbabilityCoarse": 0.0, "membershipProbabilityFine": 0.5},
        {"x": -1.0, "y": 1.0, "uri": "at://did:plc:a/com.whtwnd.blog.entry/zz", "title": "", "platform": "whitewind",
         "basePath": "", "path": "", "clusterCoarse": 2, "clusterFine": -1,
         "membershipProbabilityCoarse": 1.0, "membershipProbabilityFine": 0.0},
        {"x": 0.0, "y": 0.0001, "uri": "at://did:plc:b/site.standard.document/aa", "title": "posts/aa and aa", "platform": "leaflet",
         "basePath": "b.example", "path": "/posts/aa/aa.html", "clusterCoarse": 2, "clusterFine": 7,
         "membershipProbabilityCoarse": 0.2, "membershipProbabilityFine": 0.9},
    ]
    return {"points": points, "clusters": {"coarse": [{"id": 2}], "fine": [{"id": 7}]},
            "publications": [{"basePath": "b.example"}], "meta": {"generatedAt": "2026-10-01T00:00:00Z"}}


def page_fields(point):
    return {name: value for name, value in point.items() if not name.startswith("membershipProbability")}


def test_view_decodes_to_the_same_points_in_the_same_order():
    source = atlas()
    decoded = atlas_view.decode(json.loads(json.dumps(atlas_view.encode(source))))
    assert decoded["points"] == [page_fields(point) for point in source["points"]]
    assert {name: decoded[name] for name in ("clusters", "publications", "meta")} == \
        {name: source[name] for name in ("clusters", "publications", "meta")}


def test_points_are_stored_grouped_by_uri_with_the_order_kept_aside():
    view = atlas_view.encode(atlas())
    assert view["points"]["index"] == [1, 0, 2]
    assert view["points"]["path"] == ["", "/\x01", "/posts/\x01/\x01.html"]


def test_values_the_view_cannot_represent_are_refused():
    for change in ({"x": 0.12345}, {"path": "/a\x01b"}, {"uri": "https://example.com/a"}):
        source = atlas()
        source["points"][0].update(change)
        with pytest.raises(ValueError):
            atlas_view.encode(source)


def test_write_places_the_view_beside_the_atlas(tmp_path):
    path = tmp_path / "atlas.json.gz"
    path.write_bytes(gzip.compress(json.dumps(atlas()).encode()))
    output = atlas_view.write(path)
    assert output == tmp_path / "atlas-view.json.gz"
    assert atlas_view.decode(json.loads(gzip.decompress(output.read_bytes())))["points"][0]["uri"] == atlas()["points"][0]["uri"]


def test_restoring_an_archive_rebuilds_its_view(tmp_path):
    from atlas_history import archive, restore
    path = tmp_path / "atlas.json.gz"
    path.write_bytes(gzip.compress(json.dumps(atlas()).encode()))
    snapshot = archive(path, tmp_path / "history.sqlite3")
    restore(tmp_path / "history.sqlite3", snapshot, tmp_path / "restored")
    view = json.loads(gzip.decompress((tmp_path / "restored" / "atlas-view.json.gz").read_bytes()))
    assert atlas_view.decode(view)["meta"] == atlas()["meta"]
