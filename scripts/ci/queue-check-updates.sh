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

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

raw_packages="$tmp_dir/packages.raw"
packages_txt="$tmp_dir/packages.txt"

log "queue-check-updates[$mode]: building package queue"

if [ "$mode" = "vcs" ]; then
    sh "$ROOT_DIR/scripts/ci/run-probe-user.sh" sh "$ROOT_DIR/scripts/check-updates.sh" vcs >"$raw_packages"
else
    sh "$ROOT_DIR/scripts/check-updates.sh" regular >"$raw_packages"
fi

LC_ALL=C sort -u "$raw_packages" >"$packages_txt"

while IFS= read -r package; do
    [ -n "$package" ] || continue
    require_package_name "$package"
done <"$packages_txt"

queued_count=$(awk 'NF { count++ } END { print count + 0 }' "$packages_txt")
log "queue-check-updates[$mode]: queued=$queued_count"
if [ "$queued_count" -gt 0 ]; then
    sed 's/^/queue-check-updates['"$mode"']: queued package: /' "$packages_txt" >&2
fi

printf 'packages=%s\n' "$(sh "$ROOT_DIR/scripts/ci/json-array.sh" "$packages_txt")" >>"$GITHUB_OUTPUT"
