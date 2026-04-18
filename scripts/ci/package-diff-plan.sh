#!/bin/sh

set -eu

[ "$#" -eq 1 ] || {
    printf 'usage: package-diff-plan.sh <git-diff-name-status-file>\n' >&2
    exit 1
}

diff_file=$1
builds_json=''
removals_json=''
build_count=0
remove_count=0

append_json_item() {
    existing=$1
    package=$2
    escaped=$(printf '%s' "$package" | sed 's/\\/\\\\/g; s/"/\\"/g')
    item=$(printf '{"package":"%s"}' "$escaped")
    if [ -z "$existing" ]; then
        printf '%s' "$item"
    else
        printf '%s,%s' "$existing" "$item"
    fi
}

while IFS= read -r raw || [ -n "$raw" ]; do
    [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ] || continue

    status=$(printf '%s' "$raw" | cut -f1)

    case $status in
        R*)
            old_path=$(printf '%s' "$raw" | cut -f2)
            new_path=$(printf '%s' "$raw" | cut -f3)
            old_name=$(basename "$old_path" .sh)
            new_name=$(basename "$new_path" .sh)
            if [ "$old_name" != "template" ]; then
                removals_json=$(append_json_item "$removals_json" "$old_name")
                remove_count=$((remove_count + 1))
            fi
            if [ "$new_name" != "template" ]; then
                builds_json=$(append_json_item "$builds_json" "$new_name")
                build_count=$((build_count + 1))
            fi
            ;;
        *)
            path=$(printf '%s' "$raw" | cut -f2)
            name=$(basename "$path" .sh)
            [ "$name" = "template" ] && continue
            if [ "$status" = "D" ]; then
                removals_json=$(append_json_item "$removals_json" "$name")
                remove_count=$((remove_count + 1))
            else
                builds_json=$(append_json_item "$builds_json" "$name")
                build_count=$((build_count + 1))
            fi
            ;;
    esac
done <"$diff_file"

printf 'build_matrix={"include":[%s]}\n' "$builds_json"
printf 'remove_matrix={"include":[%s]}\n' "$removals_json"

if [ "$build_count" -gt 0 ]; then
    printf 'has_builds=true\n'
else
    printf 'has_builds=false\n'
fi

if [ "$remove_count" -gt 0 ]; then
    printf 'has_removals=true\n'
else
    printf 'has_removals=false\n'
fi
