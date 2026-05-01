#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/state.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: remove.sh <package>\n' >&2
    exit 1
}

require_update_env
require_cmd aws

name=$1
require_package_name "$name"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

state_path="$tmp_dir/$name.env"
state_download "$name" "$state_path"
state_load "$state_path"

db_archive=$(repo_db_archive_name)
repo_dir="$tmp_dir/repo"
mkdir -p "$repo_dir"

if s3_object_exists "$PKG_PREFIX/$db_archive"; then
    aws_s3_cp "$(repo_s3_uri "$db_archive")" "$repo_dir/$db_archive"
    if [ -n "$PKGNAMES" ]; then
        run_in_arch_tools --repo-mount "$repo_dir" "repo-remove \"$db_archive\" $PKGNAMES"
        materialize_repo_links "$repo_dir"
        repo_upload_databases "$repo_dir"
    fi
fi

for pkgfile in $PKGFILES; do
    repo_delete_pkgfile_pair "$pkgfile"
done

state_delete_remote "$name"
