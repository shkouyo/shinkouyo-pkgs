#!/usr/bin/env python3

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "ci" / "package-diff-plan.py"


def run_case(text: str) -> dict[str, object]:
    with tempfile.NamedTemporaryFile("w+", delete=False) as handle:
        handle.write(text)
        handle.flush()
        output = subprocess.check_output(["python3", str(SCRIPT), handle.name], text=True)

    result: dict[str, object] = {}
    for line in output.splitlines():
        key, value = line.split("=", 1)
        if key.startswith("has_"):
            result[key] = value
        else:
            result[key] = json.loads(value)
    return result


def assert_equal(actual: object, expected: object) -> None:
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


def main() -> int:
    changed = run_case(
        "A\tpackages/foo.sh\n"
        "M\tpackages/bar.sh\n"
        "D\tpackages/baz.sh\n"
        "R100\tpackages/old.sh\tpackages/new.sh\n"
        "M\tpackages/template.sh\n"
    )
    assert_equal(
        changed["build_matrix"],
        {"include": [{"package": "foo"}, {"package": "bar"}, {"package": "new"}]},
    )
    assert_equal(
        changed["remove_matrix"],
        {"include": [{"package": "baz"}, {"package": "old"}]},
    )
    assert_equal(changed["has_builds"], "true")
    assert_equal(changed["has_removals"], "true")

    empty = run_case("")
    assert_equal(empty["build_matrix"], {"include": []})
    assert_equal(empty["remove_matrix"], {"include": []})
    assert_equal(empty["has_builds"], "false")
    assert_equal(empty["has_removals"], "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
