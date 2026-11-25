LABELER_SUMMARY_URL = "https://leaflet-search-backend.fly.dev/api/labeler"


def excluded_dids(summary: dict) -> set[str]:
    authors = summary.get("authors", [])
    labeled = [author for author in authors if author.get("state") == "labeled"]
    expected = summary.get("counts", {}).get("labeled")
    if (
        type(expected) is not int
        or len(labeled) != expected
        or any(
            not isinstance(author.get("did"), str)
            or not author["did"].startswith("did:")
            or type(author.get("kept", False)) is not bool
            for author in labeled
        )
        or len({author["did"] for author in labeled}) != expected
    ):
        raise ValueError("labeler summary does not contain every labeled author")
    return {
        author["did"]
        for author in labeled
        if not author.get("kept", False)
    }


def filter_labeled_rows(rows: list[dict], excluded: set[str]) -> list[dict]:
    return [row for row in rows if row.get("did") not in excluded]
