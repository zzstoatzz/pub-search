# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = ["pytest", "httpx", "numpy<2.2", "scikit-learn", "hdbscan", "pydantic-settings"]
# ///
import runpy
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
builder = runpy.run_path(str(Path(__file__).resolve().parents[1] / "build-atlas"))


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
