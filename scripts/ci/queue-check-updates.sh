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
check_stderr="$tmp_dir/check.stderr"

log "queue-check-updates[$mode]: building package queue"

if [ "$mode" = "vcs" ]; then
    if sh "$ROOT_DIR/scripts/ci/run-probe-user.sh" sh "$ROOT_DIR/scripts/check-updates.sh" vcs >"$raw_packages" 2>"$check_stderr"; then
        check_status=0
    else
        check_status=$?
    fi
else
    if sh "$ROOT_DIR/scripts/check-updates.sh" regular >"$raw_packages" 2>"$check_stderr"; then
        check_status=0
    else
        check_status=$?
    fi
fi

cat "$check_stderr" >&2
[ "$check_status" -eq 0 ] || exit "$check_status"

summary=$(awk -v prefix="check-updates[$mode]: checked=" 'index($0, prefix) == 1 { line=$0 } END { print line }' "$check_stderr")
[ -n "$summary" ] || die "check-updates[$mode] did not print a summary"
checked_count=$(printf '%s\n' "$summary" | sed -n 's/^check-updates\[[^]]*\]: checked=\([0-9][0-9]*\) queued=.*/\1/p')
case $checked_count in
    ''|*[!0123456789]*)
        die "check-updates[$mode] printed an invalid summary: $summary"
        ;;
esac
if [ "$mode" = "vcs" ] && [ "$checked_count" -eq 0 ]; then
    die "VCS update scan did not check any packages"
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
