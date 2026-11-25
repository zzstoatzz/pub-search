# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["pytest", "httpx", "numpy<2.2", "scikit-learn", "hdbscan", "pydantic-settings"]
# ///
import base64
import json
import runpy
import sys
from pathlib import Path

import httpx
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
builder = runpy.run_path(str(Path(__file__).resolve().parents[1] / "build-atlas"))


def test_export_builds_the_same_float32_matrix_from_compact_vectors():
    values = [[-0.0, 1 / 3, -123.125], [1e-30, -1e30, 2.5]]
    expected = np.array(values, dtype="<f4")
    encoded = [base64.b64encode(vector.tobytes()).decode() for vector in expected]
    rows = [
        {"id": "a", "title": "a title", "vector": encoded[0]},
        {"id": "b", "vector": None},
        {"id": "c", "uri": "at://c", "base_path": "example", "vector": encoded[1]},
    ]
    bodies = []

    def reply(request):
        bodies.append(json.loads(request.content))
        return httpx.Response(200, json={"rows": rows})

    settings = builder["Settings"](turbopuffer_api_key="unused")
    with httpx.Client(transport=httpx.MockTransport(reply)) as client:
        exported = builder["tpuf_export"](client, settings)
    matrix, metadata = builder["atlas_matrix"](exported)

    assert bodies[0]["vector_encoding"] == "base64"
    np.testing.assert_array_equal(
        matrix.view(np.uint32), np.array(values, dtype=np.float32).view(np.uint32)
    )
    assert [row["uri"] for row in metadata] == ["a", "at://c"]
    assert metadata[0]["title"] == "a title"
    assert metadata[1]["basePath"] == "example"


def test_matrix_rejects_a_vector_that_would_broadcast_to_another_dimension():
    rows = [
        {"id": "first", "vector": base64.b64encode(np.zeros(2, dtype="<f4").tobytes()).decode()},
        {"id": "short", "vector": base64.b64encode(np.zeros(1, dtype="<f4").tobytes()).decode()},
    ]
    with pytest.raises(ValueError, match="inconsistent vector dimensions for document short"):
        builder["atlas_matrix"](rows)


def test_outliers_remain_unassigned_and_do_not_move_centroids():
    rng = np.random.default_rng(42)
    semantic = np.vstack([
        rng.normal(-2, 0.02, (40, 10)),
        rng.normal(2, 0.02, (40, 10)),
        np.full((1, 10), 1000),
    ])
    display = semantic[:, :2].copy()
    labels, centers, probability = builder["cluster_tier"]("test", semantic, display, 20, 8)
    assert labels[-1] == -1
    assert probability[-1] == 0
    assert len(centers) == 2
    assert sum(np.sum(labels == cid) for cid in centers) == 80
    for cid, center in centers.items():
        np.testing.assert_allclose(center, display[labels == cid].mean(axis=0))
        assert np.linalg.norm(center) < 3
    assert np.all((probability >= 0) & (probability <= 1))


def test_all_noise_creates_no_artificial_cluster():
    coords = np.arange(40, dtype=float).reshape(20, 2)
    labels, centers, probability = builder["cluster_tier"]("noise", coords, coords, 20, 5)
    assert np.all(labels == -1)
    assert centers == {}
    assert np.all(probability == 0)


def test_titles_never_borrow_from_unassigned_documents():
    titles = builder["titles_by_membership"](
        np.array([0, 0, 1, -1]),
        [{"title": "agents"}, {"title": ""}, {"title": ""}, {"title": "friendship"}],
    )
    assert titles == {0: ["agents"], 1: []}
    assert builder["cluster_labels"](titles)[1] == "cluster 1"


def test_parent_is_association_among_actual_members_or_none():
    fine = np.array([0, 0, 0, 1, 1, 2, 2, 2, -1])
    coarse = np.array([-1, -1, 4, -1, -1, 4, 5, 5, 8])
    assert builder["parent_memberships"](fine, coarse) == {0: 4, 1: None, 2: 5}


def test_export_rejects_inflated_counts_and_invalid_noise_strength():
    from copy import deepcopy

    output = {
        "points": [
            {"clusterCoarse": 0, "clusterFine": 1,
             "membershipProbabilityCoarse": 0.9, "membershipProbabilityFine": 1},
            {"clusterCoarse": -1, "clusterFine": -1,
             "membershipProbabilityCoarse": 0, "membershipProbabilityFine": 0},
        ],
        "clusters": {"coarse": [{"id": 0, "count": 1}],
                     "fine": [{"id": 1, "count": 1, "parent": 0}]},
        "meta": {"nUnassignedCoarse": 1, "nUnassignedFine": 1},
    }
    builder["validate_memberships"](output)
    inflated = deepcopy(output)
    inflated["clusters"]["fine"][0]["count"] = 2
    with pytest.raises(ValueError, match="incorrect fine member count"):
        builder["validate_memberships"](inflated)
    bad_noise = deepcopy(output)
    bad_noise["points"][1]["membershipProbabilityFine"] = 0.5
    with pytest.raises(ValueError, match="invalid fine membership strength"):
        builder["validate_memberships"](bad_noise)


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
