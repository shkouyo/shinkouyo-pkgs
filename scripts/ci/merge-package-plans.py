#!/usr/bin/env python3

from __future__ import annotations

import json
import os


def load_packages(result_key: str, packages_key: str) -> list[str]:
    result = os.environ.get(result_key, "")
    if result in {"", "skipped"}:
        return []
    if result != "success":
        raise SystemExit(f"{result_key}={result} is not mergeable")

    raw = os.environ.get(packages_key, "")
    if not raw:
        return []

    data = json.loads(raw)
    if not isinstance(data, list):
        raise SystemExit(f"{packages_key} is not a JSON array")
    return [str(item) for item in data if str(item).strip()]


def main() -> int:
    packages = sorted(
        set(
            load_packages("REGULAR_RESULT", "REGULAR_PACKAGES")
            + load_packages("VCS_RESULT", "VCS_PACKAGES")
        )
    )
    matrix = {"include": [{"package": package} for package in packages]}
    print(f"matrix={json.dumps(matrix)}")
    print(f"has_items={'true' if packages else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
