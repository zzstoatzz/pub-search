"""Shared Fly Machine discovery helpers for snapshot operations."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from typing import Any

BUILDER_NAME = "snapshot-builder-hourly"


def one(items: list[dict[str, Any]], description: str) -> dict[str, Any]:
    if len(items) != 1:
        raise RuntimeError(f"expected one {description}, found {len(items)}")
    return items[0]


def select_builder(machines: list[dict[str, Any]]) -> dict[str, Any]:
    return one([m for m in machines if m.get("name") == BUILDER_NAME], "snapshot builder")


def select_serving(machines: list[dict[str, Any]]) -> dict[str, Any]:
    candidates = [
        m
        for m in machines
        if m.get("state") == "started"
        and m.get("config", {}).get("env", {}).get("FLY_PROCESS_GROUP") == "app"
    ]
    return one(candidates, "started serving machine")


def image_uri(machine: dict[str, Any]) -> str:
    ref = machine.get("image_ref", {})
    required = ("registry", "repository", "tag", "digest")
    if any(not ref.get(key) for key in required):
        raise RuntimeError(f"machine {machine.get('id', '?')} has incomplete image_ref")
    return f"{ref['registry']}/{ref['repository']}:{ref['tag']}@{ref['digest']}"


def fly_binary() -> str:
    configured = os.environ.get("FLY_BIN")
    if configured:
        return configured
    return shutil.which("flyctl") or shutil.which("fly") or "flyctl"


def machine_list(fly: str, app: str) -> list[dict[str, Any]]:
    output = subprocess.check_output([fly, "machines", "list", "-a", app, "--json"], text=True)
    value = json.loads(output)
    if not isinstance(value, list):
        raise RuntimeError("fly machines list returned a non-list response")
    return value
