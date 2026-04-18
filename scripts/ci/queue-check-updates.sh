#!/bin/sh

set -eu

CI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CI_DIR/../.." && pwd)

. "$ROOT_DIR/scripts/lib/common.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: queue-check-updates.sh <regular|vcs>\n' >&2
    exit 1
}

mode=$1
case $mode in
    regular|vcs) ;;
    *) die "unsupported mode: $mode" ;;
esac

packages_txt=${RUNNER_TEMP:-/tmp}/packages.txt

if [ "$mode" = "vcs" ]; then
    sh "$ROOT_DIR/scripts/ci/run-probe-user.sh" sh "$ROOT_DIR/scripts/check-updates.sh" vcs \
        | LC_ALL=C sort -u >"$packages_txt"
else
    sh "$ROOT_DIR/scripts/check-updates.sh" regular | LC_ALL=C sort -u >"$packages_txt"
fi

printf 'packages=%s\n' "$(sh "$ROOT_DIR/scripts/ci/json-array.sh" "$packages_txt")" >>"$GITHUB_OUTPUT"
