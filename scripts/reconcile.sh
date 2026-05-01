#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/state.sh"

require_update_env
require_cmd aws

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

states_dir="$tmp_dir/states"
repo_dir="$tmp_dir/repo"
packages_dir="$tmp_dir/packages"
mkdir -p "$states_dir" "$repo_dir" "$packages_dir"

aws_s3_cp --recursive "s3://$S3_BUCKET/$STATE_PREFIX/" "$states_dir/" >/dev/null 2>&1 || :

db_archive=$(repo_db_archive_name)

good_packages=''

for state_file in "$states_dir"/*.env; do
    [ -e "$state_file" ] || continue
    state_load "$state_file"

    missing=0
    repo_pkgfiles_exist "$PKGFILES" || missing=1

    if [ "$missing" = "1" ]; then
        for pkgfile in $PKGFILES; do
            repo_delete_pkgfile_pair "$pkgfile"
        done
        state_delete_remote "$NAME"
        continue
    fi

    for pkgfile in $PKGFILES; do
        local_path="$packages_dir/$pkgfile"
        aws_s3_cp "$(repo_s3_uri "$pkgfile")" "$local_path"
        aws_s3_cp "$(repo_s3_uri "$pkgfile.sig")" "$local_path.sig"
        good_packages="$good_packages /extra/$pkgfile"
    done
done

if [ -n "$good_packages" ]; then
    run_in_arch_tools --repo-mount "$repo_dir" --extra-mount "$packages_dir" "repo-add \"$db_archive\"$good_packages"
    materialize_repo_links "$repo_dir"
    repo_upload_databases "$repo_dir"
else
    repo_delete_databases_if_present
fi
