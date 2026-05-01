#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/state.sh"

[ "$#" -eq 2 ] || {
    printf 'usage: stage.sh <context_dir> <stage_id>\n' >&2
    exit 1
}

require_repo_env
require_cmd aws

context_dir=$1
stage_id=$2
require_stage_id "$stage_id"

state_load "$context_dir/state.env"
package=$NAME
stage_rel="$package/$stage_id"

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

remote_artifacts="$tmp_dir/artifacts.list"
: >"$remote_artifacts"

while IFS= read -r pkgfile; do
    [ -n "$pkgfile" ] || continue
    base=$(basename "$pkgfile")
    case $base in
        */*|'') die "invalid artifact path: $pkgfile" ;;
    esac
    [ -f "$pkgfile" ] || die "missing artifact: $pkgfile"
    [ -f "$pkgfile.sig" ] || die "missing artifact signature: $pkgfile.sig"

    aws_s3_cp "$pkgfile" "$(incoming_s3_uri "$stage_rel/$base")"
    aws_s3_cp "$pkgfile.sig" "$(incoming_s3_uri "$stage_rel/$base.sig")"
    printf '%s\n' "$base" >>"$remote_artifacts"
done <"$context_dir/artifacts.list"

[ -s "$remote_artifacts" ] || die "artifacts.list is empty"

aws_s3_cp "$context_dir/state.env" "$(incoming_s3_uri "$stage_rel/state.env")"
aws_s3_cp "$remote_artifacts" "$(incoming_s3_uri "$stage_rel/artifacts.list")"

ready_file="$tmp_dir/ready"
{
    printf 'PACKAGE=%s\n' "$(shell_quote "$package")"
    printf 'STAGE_ID=%s\n' "$(shell_quote "$stage_id")"
} >"$ready_file"

aws_s3_cp "$ready_file" "$(incoming_s3_uri "$stage_rel/ready")"
