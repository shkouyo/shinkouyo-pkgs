#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: json-array.py <text-file>")

    items = [
        line.strip()
        for line in pathlib.Path(sys.argv[1]).read_text().splitlines()
        if line.strip()
    ]
    print(json.dumps(items))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
