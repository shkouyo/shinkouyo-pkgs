#!/bin/sh

set -eu

CI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CI_DIR/../.." && pwd)

. "$ROOT_DIR/scripts/lib/common.sh"

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

load_packages() {
    result_key=$1
    packages_key=$2

    result=
    eval "result=\${$result_key-}"
    case $result in
        ''|skipped)
            return 0
            ;;
        success)
            ;;
        *)
            printf '%s=%s is not mergeable\n' "$result_key" "$result" >&2
            exit 1
            ;;
    esac

    raw=
    eval "raw=\${$packages_key-}"
    [ -n "$raw" ] || return 0

    printf '%s' "$raw" \
        | tr -d '\n' \
        | sed -e 's/^\[//' -e 's/\]$//' \
        | tr ',' '\n' \
        | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' -e 's/^ *//' -e 's/ *$//' \
        | sed '/^$/d'
}

packages_raw="$tmp_dir/packages.raw"
packages_sorted="$tmp_dir/packages.sorted"
: >"$packages_raw"

load_packages REGULAR_RESULT REGULAR_PACKAGES >>"$packages_raw"
printf '\n' >>"$packages_raw"
load_packages VCS_RESULT VCS_PACKAGES >>"$packages_raw"
printf '\n' >>"$packages_raw"
sed '/^$/d' "$packages_raw" | LC_ALL=C sort -u >"$packages_sorted"

if [ -s "$packages_sorted" ]; then
    printf 'matrix={"include":['
    first=1
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        require_package_name "$package"
        escaped=$(printf '%s' "$package" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '{"package":"%s"}' "$escaped"
    done <"$packages_sorted"
    printf ']}\n'
else
    printf 'matrix={"include":[{"package":"no-packages"}]}\n'
fi

if [ -s "$packages_sorted" ]; then
    printf 'has_items=true\n'
else
    printf 'has_items=false\n'
fi
