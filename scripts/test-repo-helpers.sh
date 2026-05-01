#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

bin_dir="$tmp_dir/bin"
object_dir="$tmp_dir/objects"
aws_log="$tmp_dir/aws.log"
mkdir -p "$bin_dir" "$object_dir/$PKG_PREFIX"
: >"$aws_log"

cat >"$bin_dir/aws" <<'EOF'
#!/bin/sh

set -eu

uri_key() {
    uri=$1
    case $uri in
        s3://"$S3_BUCKET"/*)
            printf '%s\n' "${uri#s3://$S3_BUCKET/}"
            ;;
        *)
            printf 'unsupported uri: %s\n' "$uri" >&2
            exit 2
            ;;
    esac
}

case "${1-}:${2-}" in
    s3:cp)
        shift 2
        if [ "${1-}" = "--endpoint-url" ]; then
            shift 2
        fi
        [ "$#" -eq 2 ] || exit 2

        src=$1
        dest=$2
        printf 'cp %s %s\n' "$src" "$dest" >>"$TEST_AWS_LOG"
        case $src in
            s3://*)
                key=$(uri_key "$src")
                cp "$TEST_OBJECT_DIR/$key" "$dest"
                ;;
            *)
                key=$(uri_key "$dest")
                mkdir -p "$(dirname "$TEST_OBJECT_DIR/$key")"
                cp "$src" "$TEST_OBJECT_DIR/$key"
                ;;
        esac
        ;;
    s3:rm)
        shift 2
        if [ "${1-}" = "--endpoint-url" ]; then
            shift 2
        fi
        [ "$#" -eq 1 ] || exit 2

        key=$(uri_key "$1")
        printf 'rm %s\n' "$1" >>"$TEST_AWS_LOG"
        rm -f "$TEST_OBJECT_DIR/$key"
        ;;
    s3api:head-object)
        shift 2
        key=''
        while [ "$#" -gt 0 ]; do
            case $1 in
                --endpoint-url|--bucket)
                    shift 2
                    ;;
                --key)
                    key=$2
                    shift 2
                    ;;
                *)
                    exit 2
                    ;;
            esac
        done
        [ -n "$key" ] || exit 2
        [ -f "$TEST_OBJECT_DIR/$key" ] || exit 1
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$bin_dir/aws"

export PATH="$bin_dir:$PATH"
export TEST_OBJECT_DIR="$object_dir"
export TEST_AWS_LOG="$aws_log"
export REPO_NAME='repo-test'
export S3_BUCKET='repo-bucket'
export S3_ENDPOINT='https://example.invalid'
export S3_REGION='auto'

pkg_a='demo-1-1-any.pkg.tar.zst'
pkg_b='other-1-1-any.pkg.tar.zst'

printf '%s\n' package >"$object_dir/$PKG_PREFIX/$pkg_a"
if repo_pkgfile_pair_exists "$pkg_a"; then
    die 'repo_pkgfile_pair_exists accepted package without signature'
fi

printf '%s\n' signature >"$object_dir/$PKG_PREFIX/$pkg_a.sig"
repo_pkgfile_pair_exists "$pkg_a" || die 'repo_pkgfile_pair_exists rejected complete package pair'

if repo_pkgfiles_exist "$pkg_a $pkg_b"; then
    die 'repo_pkgfiles_exist accepted a missing package pair'
fi

printf '%s\n' package >"$object_dir/$PKG_PREFIX/$pkg_b"
printf '%s\n' signature >"$object_dir/$PKG_PREFIX/$pkg_b.sig"
repo_pkgfiles_exist "$pkg_a $pkg_b" || die 'repo_pkgfiles_exist rejected complete package pairs'

repo_delete_pkgfile_pair "$pkg_a"
[ ! -e "$object_dir/$PKG_PREFIX/$pkg_a" ] || die 'repo_delete_pkgfile_pair left package object'
[ ! -e "$object_dir/$PKG_PREFIX/$pkg_a.sig" ] || die 'repo_delete_pkgfile_pair left signature object'
[ -e "$object_dir/$PKG_PREFIX/$pkg_b" ] || die 'repo_delete_pkgfile_pair removed unrelated package'

repo_dir="$tmp_dir/repo"
missing_repo_dir="$tmp_dir/missing-repo"
mkdir -p "$repo_dir" "$missing_repo_dir"

db_archive=$(repo_db_archive_name)
db_name=$(repo_db_name)
files_archive=$(repo_files_archive_name)
files_name=$(repo_files_name)

printf '%s\n' remote-db >"$object_dir/$PKG_PREFIX/$db_archive"
repo_download_existing_databases "$repo_dir"
[ -f "$repo_dir/$db_archive" ] || die 'repo_download_existing_databases did not download existing db archive'
[ ! -e "$repo_dir/$files_archive" ] || die 'repo_download_existing_databases downloaded missing files archive'

printf '%s\n' local-db-archive >"$repo_dir/$db_archive"
printf '%s\n' local-db-link >"$repo_dir/$db_name"
printf '%s\n' local-files-archive >"$repo_dir/$files_archive"
printf '%s\n' local-files-link >"$repo_dir/$files_name"

repo_upload_databases "$repo_dir"
cmp "$repo_dir/$db_archive" "$object_dir/$PKG_PREFIX/$db_archive" >/dev/null ||
    die 'repo_upload_databases uploaded wrong db archive'
cmp "$repo_dir/$db_name" "$object_dir/$PKG_PREFIX/$db_name" >/dev/null ||
    die 'repo_upload_databases uploaded wrong db link'
cmp "$repo_dir/$files_archive" "$object_dir/$PKG_PREFIX/$files_archive" >/dev/null ||
    die 'repo_upload_databases uploaded wrong files archive'
cmp "$repo_dir/$files_name" "$object_dir/$PKG_PREFIX/$files_name" >/dev/null ||
    die 'repo_upload_databases uploaded wrong files link'

printf '%s\n' only-db >"$missing_repo_dir/$db_archive"
if ( repo_upload_databases "$missing_repo_dir" ) >/dev/null 2>&1; then
    die 'repo_upload_databases accepted incomplete repo database set'
fi

repo_delete_databases_if_present
for object_name in "$db_archive" "$db_name" "$files_archive" "$files_name"; do
    [ ! -e "$object_dir/$PKG_PREFIX/$object_name" ] ||
        die "repo_delete_databases_if_present left $object_name"
done

printf '%s\n' 'repo helper checks passed'
