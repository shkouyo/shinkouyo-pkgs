#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$SCRIPT_DIR/state.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: publish.sh <context_dir>\n' >&2
    exit 1
}

require_publish_env
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
files_archive=$(repo_files_archive_name)
db_name=$(repo_db_name)
files_name=$(repo_files_name)

old_state_file="$repo_dir/old-state.env"
old_pkgfiles=''
if state_download "$new_name" "$old_state_file" >/dev/null 2>&1; then
    eval "$(state_emit_prefixed OLD "$old_state_file")"
    old_pkgfiles=$OLD_PKGFILES
fi

if s3_object_exists "$PKG_PREFIX/$db_archive"; then
    aws_s3_cp "$(repo_s3_uri "$db_archive")" "$repo_dir/$db_archive"
fi
if s3_object_exists "$PKG_PREFIX/$files_archive"; then
    aws_s3_cp "$(repo_s3_uri "$files_archive")" "$repo_dir/$files_archive"
fi

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

aws_s3_cp "$repo_dir/$db_archive" "$(repo_s3_uri "$db_archive")"
aws_s3_cp "$repo_dir/$db_name" "$(repo_s3_uri "$db_name")"
aws_s3_cp "$repo_dir/$files_archive" "$(repo_s3_uri "$files_archive")"
aws_s3_cp "$repo_dir/$files_name" "$(repo_s3_uri "$files_name")"

for old_pkgfile in $old_pkgfiles; do
    case " $new_pkgfiles " in
        *" $old_pkgfile "*) continue ;;
    esac
    if s3_object_exists "$PKG_PREFIX/$old_pkgfile"; then
        aws_s3_rm "$(repo_s3_uri "$old_pkgfile")"
    fi
    if s3_object_exists "$PKG_PREFIX/$old_pkgfile.sig"; then
        aws_s3_rm "$(repo_s3_uri "$old_pkgfile.sig")"
    fi
done

state_upload "$new_name" "$context_dir/state.env"
