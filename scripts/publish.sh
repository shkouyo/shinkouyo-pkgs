#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/state.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: publish.sh <context_dir>\n' >&2
    exit 1
}

require_repo_env
require_cmd aws

context_dir=$1
# shellcheck disable=SC1090
. "$context_dir/context.env"
state_load "$context_dir/state.env"

new_name=$NAME
new_pkgfiles=$PKGFILES

repo_dir=$(mktemp -d)
trap 'rm -rf "$repo_dir"' EXIT HUP INT TERM

db_archive=$(repo_db_archive_name)

old_state_file="$repo_dir/old-state.env"
old_pkgfiles=''
if state_download "$new_name" "$old_state_file" >/dev/null 2>&1; then
    eval "$(state_emit_prefixed OLD "$old_state_file")"
    old_pkgfiles=$OLD_PKGFILES
fi

repo_download_existing_databases "$repo_dir"

pkg_args_extra=''
artifacts_dir=''
while IFS= read -r pkgfile; do
    [ -n "$pkgfile" ] || continue
    pkgdir=$(dirname "$pkgfile")
    if [ -z "$artifacts_dir" ]; then
        artifacts_dir=$pkgdir
    elif [ "$artifacts_dir" != "$pkgdir" ]; then
        die "artifacts.list contains files from multiple directories"
    fi
    pkg_args_extra="$pkg_args_extra /extra/$(basename "$pkgfile")"
done <"$context_dir/artifacts.list"
[ -n "$pkg_args_extra" ] || die "artifacts.list is empty"
[ -n "$artifacts_dir" ] || die "failed to determine artifacts directory"

run_in_arch_tools --repo-mount "$repo_dir" --extra-mount "$artifacts_dir" "repo-add \"$db_archive\"$pkg_args_extra"
materialize_repo_links "$repo_dir"

while IFS= read -r pkgfile; do
    [ -n "$pkgfile" ] || continue
    base=$(basename "$pkgfile")
    aws_s3_cp "$pkgfile" "$(repo_s3_uri "$base")"
    aws_s3_cp "$pkgfile.sig" "$(repo_s3_uri "$base.sig")"
done <"$context_dir/artifacts.list"

repo_upload_databases "$repo_dir"

for old_pkgfile in $old_pkgfiles; do
    case " $new_pkgfiles " in
        *" $old_pkgfile "*) continue ;;
    esac
    repo_delete_pkgfile_pair "$old_pkgfile"
done

state_upload "$new_name" "$context_dir/state.env"
