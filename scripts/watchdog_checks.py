"""Pure watchdog policy helpers, kept separate from network and auth code."""

SNAPSHOT_AGE_ALERT_MINUTES = 120


def snapshot_age_minutes(manifest: object, now_timestamp: float) -> float:
    if not isinstance(manifest, dict):
        raise ValueError("snapshot manifest body is not an object")
    created_at = manifest.get("created_at")
    if not isinstance(created_at, (int, float)) or created_at <= 0:
        raise ValueError("snapshot manifest has invalid created_at")
    return (now_timestamp - created_at) / 60


def snapshot_age_problem(manifest: object, now_timestamp: float) -> str | None:
    if not isinstance(manifest, dict):
        return "snapshot manifest body is not an object"

    build_id = manifest.get("build_id", "?")
    created_at = manifest.get("created_at")
    if not isinstance(created_at, (int, float)) or created_at <= 0:
        return f"snapshot manifest has invalid created_at (build {build_id})"

    age_minutes = snapshot_age_minutes(manifest, now_timestamp)
    if age_minutes > SNAPSHOT_AGE_ALERT_MINUTES:
        return (
            f"serving snapshot is {age_minutes:.0f}m old "
            f"(build {build_id}) - freshness bound exceeded; builder or adoption delayed"
        )
    return None
