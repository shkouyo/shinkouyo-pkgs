#!/bin/sh

set -eu

[ "$#" -eq 1 ] || {
    printf 'usage: json-array.sh <text-file>\n' >&2
    exit 1
}

awk '
BEGIN {
    printf("[")
    first = 1
}
{
    line = $0
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]+$/, "", line)
    if (line == "") {
        next
    }

    gsub(/\\/, "\\\\", line)
    gsub(/"/, "\\\"", line)

    if (!first) {
        printf(",")
    }
    printf("\"%s\"", line)
    first = 0
}
END {
    printf("]\n")
}
' "$1"
