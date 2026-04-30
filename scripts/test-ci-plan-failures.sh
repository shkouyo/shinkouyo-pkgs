#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

output_file="$tmp_dir/github-output"

if GITHUB_OUTPUT="$output_file" sh "$ROOT_DIR/scripts/ci/queue-check-updates.sh" regular >/dev/null 2>&1; then
    printf 'expected queue-check-updates.sh to fail without required env\n' >&2
    exit 1
fi

if [ -s "$output_file" ]; then
    printf 'queue-check-updates.sh wrote output after failure\n' >&2
    exit 1
fi

if REGULAR_RESULT=failure sh "$ROOT_DIR/scripts/ci/merge-package-plans.sh" >/dev/null 2>&1; then
    printf 'expected merge-package-plans.sh to fail on failed plan job\n' >&2
    exit 1
fi

if REGULAR_RESULT=success REGULAR_PACKAGES='["BadName"]' sh "$ROOT_DIR/scripts/ci/merge-package-plans.sh" >/dev/null 2>&1; then
    printf 'expected merge-package-plans.sh to fail on invalid package name\n' >&2
    exit 1
fi

REGULAR_RESULT=success \
REGULAR_PACKAGES='["foo","bar"]' \
VCS_RESULT=success \
VCS_PACKAGES='["foo","baz"]' \
    sh "$ROOT_DIR/scripts/ci/merge-package-plans.sh" >"$tmp_dir/merge.out"

grep -F -x 'matrix={"include":[{"package":"bar"},{"package":"baz"},{"package":"foo"}]}' "$tmp_dir/merge.out" >/dev/null
grep -F -x 'has_items=true' "$tmp_dir/merge.out" >/dev/null

printf '%s\n' 'ci plan failure checks passed'
