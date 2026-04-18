#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: package-diff-plan.py <git-diff-name-status-file>")

    diff_path = pathlib.Path(sys.argv[1])
    builds: list[dict[str, str]] = []
    removals: list[dict[str, str]] = []

    for raw in diff_path.read_text().splitlines():
        if not raw.strip():
            continue

        parts = raw.split("\t")
        status = parts[0]
        if status.startswith("R"):
            old_path, new_path = parts[1], parts[2]
            old_name = pathlib.Path(old_path).stem
            new_name = pathlib.Path(new_path).stem
            if old_name != "template":
                removals.append({"package": old_name})
            if new_name != "template":
                builds.append({"package": new_name})
            continue

        path = parts[1]
        name = pathlib.Path(path).stem
        if name == "template":
            continue
        if status == "D":
            removals.append({"package": name})
        else:
            builds.append({"package": name})

    print(f"build_matrix={json.dumps({'include': builds})}")
    print(f"remove_matrix={json.dumps({'include': removals})}")
    print(f"has_builds={'true' if builds else 'false'}")
    print(f"has_removals={'true' if removals else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
