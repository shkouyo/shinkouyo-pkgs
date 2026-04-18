#!/bin/sh

set -eu

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

packages=$(
    {
        load_packages REGULAR_RESULT REGULAR_PACKAGES
        load_packages VCS_RESULT VCS_PACKAGES
    } | LC_ALL=C sort -u
)

printf 'matrix={"include":['
first=1
if [ -n "$packages" ]; then
    printf '%s\n' "$packages" | while IFS= read -r package; do
        [ -n "$package" ] || continue
        escaped=$(printf '%s' "$package" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '{"package":"%s"}' "$escaped"
    done
fi
printf ']}\n'

if [ -n "$packages" ]; then
    printf 'has_items=true\n'
else
    printf 'has_items=false\n'
fi
