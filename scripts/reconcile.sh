#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
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
files_archive=$(repo_files_archive_name)
db_name=$(repo_db_name)
files_name=$(repo_files_name)

good_packages=''

for state_file in "$states_dir"/*.env; do
    [ -e "$state_file" ] || continue
    state_load "$state_file"

    missing=0
    for pkgfile in $PKGFILES; do
        if ! s3_object_exists "$PKG_PREFIX/$pkgfile" || ! s3_object_exists "$PKG_PREFIX/$pkgfile.sig"; then
            missing=1
            break
        fi
    done

    if [ "$missing" = "1" ]; then
        for pkgfile in $PKGFILES; do
            if s3_object_exists "$PKG_PREFIX/$pkgfile"; then
                aws_s3_rm "$(repo_s3_uri "$pkgfile")"
            fi
            if s3_object_exists "$PKG_PREFIX/$pkgfile.sig"; then
                aws_s3_rm "$(repo_s3_uri "$pkgfile.sig")"
            fi
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
    aws_s3_cp "$repo_dir/$db_archive" "$(repo_s3_uri "$db_archive")"
    aws_s3_cp "$repo_dir/$db_name" "$(repo_s3_uri "$db_name")"
    aws_s3_cp "$repo_dir/$files_archive" "$(repo_s3_uri "$files_archive")"
    aws_s3_cp "$repo_dir/$files_name" "$(repo_s3_uri "$files_name")"
else
    for object_name in "$db_archive" "$db_name" "$files_archive" "$files_name"; do
        if s3_object_exists "$PKG_PREFIX/$object_name"; then
            aws_s3_rm "$(repo_s3_uri "$object_name")"
        fi
    done
fi
