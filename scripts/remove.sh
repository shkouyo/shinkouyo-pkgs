#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$SCRIPT_DIR/state.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: remove.sh <package>\n' >&2
    exit 1
}

require_update_env
require_cmd aws

name=$1
[ "$name" != "template" ] || die "template manifest is not removable"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

state_path="$tmp_dir/$name.env"
state_download "$name" "$state_path"
state_load "$state_path"

db_archive=$(repo_db_archive_name)
files_archive=$(repo_files_archive_name)
db_name=$(repo_db_name)
files_name=$(repo_files_name)
repo_dir="$tmp_dir/repo"
mkdir -p "$repo_dir"

if s3_object_exists "$PKG_PREFIX/$db_archive"; then
    aws_s3_cp "$(repo_s3_uri "$db_archive")" "$repo_dir/$db_archive"
    if [ -n "$PKGNAMES" ]; then
        run_in_arch_tools --repo-mount "$repo_dir" "repo-remove \"$db_archive\" $PKGNAMES"
        materialize_repo_links "$repo_dir"
        aws_s3_cp "$repo_dir/$db_archive" "$(repo_s3_uri "$db_archive")"
        aws_s3_cp "$repo_dir/$db_name" "$(repo_s3_uri "$db_name")"
        aws_s3_cp "$repo_dir/$files_archive" "$(repo_s3_uri "$files_archive")"
        aws_s3_cp "$repo_dir/$files_name" "$(repo_s3_uri "$files_name")"
    fi
fi

for pkgfile in $PKGFILES; do
    if s3_object_exists "$PKG_PREFIX/$pkgfile"; then
        aws_s3_rm "$(repo_s3_uri "$pkgfile")"
    fi
    if s3_object_exists "$PKG_PREFIX/$pkgfile.sig"; then
        aws_s3_rm "$(repo_s3_uri "$pkgfile.sig")"
    fi
done

state_delete_remote "$name"
