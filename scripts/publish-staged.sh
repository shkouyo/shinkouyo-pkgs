#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/state.sh"

require_repo_env
require_cmd aws

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

ready_keys="$tmp_dir/ready.keys"
all_keys="$tmp_dir/all.keys"
selected="$tmp_dir/selected.tsv"
stale="$tmp_dir/stale.tsv"

s3_list_keys "$INCOMING_PREFIX" >"$all_keys"
awk -v prefix="$INCOMING_PREFIX/" '
    index($0, prefix) == 1 && $0 ~ /\/ready$/ {
        rel = substr($0, length(prefix) + 1)
        n = split(rel, parts, "/")
        if (n == 3 && parts[1] != "" && parts[2] != "" && parts[3] == "ready") {
            print parts[1] "\t" parts[2]
        }
    }
' "$all_keys" >"$ready_keys"

if [ ! -s "$ready_keys" ]; then
    log "No staged builds ready to publish"
    cleanup
    exit 0
fi

: >"$selected"
: >"$stale"

while IFS='	' read -r package stage_id; do
    [ -n "$package" ] || continue
    require_package_name "$package"
    require_stage_id "$stage_id"
    run_id=${stage_id%-*}
    run_attempt=${stage_id##*-}
    [ "$run_id" != "$stage_id" ] || die "stage id must be <run_id>-<run_attempt>: $stage_id"
    case $run_id:$run_attempt in
        *[!0123456789:]*|':'*|*':') die "stage id must be <run_id>-<run_attempt>: $stage_id" ;;
    esac

    current_line=$(awk -F '	' -v package="$package" '$1 == package { print; exit }' "$selected")
    if [ -z "$current_line" ]; then
        printf '%s\t%s\t%s\t%s\n' "$package" "$stage_id" "$run_id" "$run_attempt" >>"$selected"
        continue
    fi

    current_stage=$(printf '%s\n' "$current_line" | awk -F '	' '{ print $2 }')
    current_run=$(printf '%s\n' "$current_line" | awk -F '	' '{ print $3 }')
    current_attempt=$(printf '%s\n' "$current_line" | awk -F '	' '{ print $4 }')

    if [ "$run_id" -gt "$current_run" ] ||
        { [ "$run_id" -eq "$current_run" ] && [ "$run_attempt" -gt "$current_attempt" ]; }; then
        printf '%s\t%s\n' "$package" "$current_stage" >>"$stale"
        awk -F '	' -v package="$package" '$1 != package' "$selected" >"$selected.tmp"
        mv "$selected.tmp" "$selected"
        printf '%s\t%s\t%s\t%s\n' "$package" "$stage_id" "$run_id" "$run_attempt" >>"$selected"
    else
        printf '%s\t%s\n' "$package" "$stage_id" >>"$stale"
    fi
done <"$ready_keys"

cleanup_stage() {
    cleanup_package=$1
    cleanup_stage_id=$2
    aws_s3_rm_recursive "$(incoming_s3_uri "$cleanup_package/$cleanup_stage_id")" >/dev/null
}

while IFS='	' read -r package stage_id; do
    [ -n "$package" ] || continue
    log "$package: dropping stale staged build $stage_id"
    cleanup_stage "$package" "$stage_id"
done <"$stale"

LC_ALL=C sort "$selected" |
    while IFS='	' read -r package stage_id _run_id _run_attempt; do
        [ -n "$package" ] || continue

        if [ ! -f "$ROOT_DIR/packages/$package.sh" ]; then
            log "$package: package manifest removed, dropping staged build $stage_id"
            cleanup_stage "$package" "$stage_id"
            continue
        fi

        stage_dir="$tmp_dir/stages/$package/$stage_id"
        context_dir="$stage_dir/context"
        artifacts_dir="$stage_dir/artifacts"
        mkdir -p "$context_dir" "$artifacts_dir"
        : >"$context_dir/context.env"

        aws_s3_cp "$(incoming_s3_uri "$package/$stage_id/state.env")" "$context_dir/state.env"
        state_load "$context_dir/state.env"
        [ "$NAME" = "$package" ] || die "$package: staged state NAME mismatch: $NAME"
        aws_s3_cp "$(incoming_s3_uri "$package/$stage_id/artifacts.list")" "$stage_dir/artifacts.remote"

        : >"$context_dir/artifacts.list"
        while IFS= read -r base; do
            [ -n "$base" ] || continue
            case $base in
                */*|'') die "$package: invalid staged artifact name: $base" ;;
            esac
            aws_s3_cp "$(incoming_s3_uri "$package/$stage_id/$base")" "$artifacts_dir/$base"
            aws_s3_cp "$(incoming_s3_uri "$package/$stage_id/$base.sig")" "$artifacts_dir/$base.sig"
            printf '%s/%s\n' "$artifacts_dir" "$base" >>"$context_dir/artifacts.list"
        done <"$stage_dir/artifacts.remote"

        log "$package: publishing staged build $stage_id"
        sh "$SCRIPT_DIR/publish.sh" "$context_dir"
        cleanup_stage "$package" "$stage_id"
    done
