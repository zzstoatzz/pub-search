import re
import unittest
from pathlib import Path

DASHBOARD_CSS = Path(__file__).resolve().parents[2] / "site" / "dashboard.css"


def rule(selector: str) -> str:
    match = re.search(re.escape(selector) + r"\s*\{([^}]*)\}", DASHBOARD_CSS.read_text())
    assert match, f"{selector} rule missing from dashboard.css"
    return match.group(1)


class LatencyGridTests(unittest.TestCase):
    def test_columns_reflow_instead_of_overflowing_narrow_screens(self):
        # the cell labels are white-space:nowrap, so a fixed column count
        # of bare `1fr` tracks (min-content floor) pushes the page wider
        # than a phone viewport.
        columns = re.search(r"grid-template-columns:\s*([^;]+);", rule(".latency-grid")).group(1)
        self.assertRegex(columns, r"^repeat\(auto-fill,\s*minmax\(\d+px,\s*1fr\)\)$")
        self.assertIn("white-space: nowrap", rule(".latency-cell-max"))
