#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$ROOT/ci/package-diff-plan.sh"

assert_contains_line() {
    output=$1
    expected=$2
    printf '%s\n' "$output" | grep -F -x "$expected" >/dev/null || {
        printf 'expected line not found: %s\n' "$expected" >&2
        printf 'actual output:\n%s\n' "$output" >&2
        exit 1
    }
}

run_case() {
    text=$1
    tmp=$(mktemp)
    printf '%s' "$text" >"$tmp"
    sh "$SCRIPT" "$tmp"
    rm -f "$tmp"
}

changed=$(run_case "$(printf 'A\tpackages/foo.sh\nM\tpackages/bar.sh\nD\tpackages/baz.sh\nR100\tpackages/old.sh\tpackages/new.sh\nM\tpackages/template.sh\n')")
assert_contains_line "$changed" 'build_matrix={"include":[{"package":"foo"},{"package":"bar"},{"package":"new"}]}'
assert_contains_line "$changed" 'remove_matrix={"include":[{"package":"baz"},{"package":"old"}]}'
assert_contains_line "$changed" 'has_builds=true'
assert_contains_line "$changed" 'has_removals=true'

empty=$(run_case '')
assert_contains_line "$empty" 'build_matrix={"include":[]}'
assert_contains_line "$empty" 'remove_matrix={"include":[]}'
assert_contains_line "$empty" 'has_builds=false'
assert_contains_line "$empty" 'has_removals=false'
