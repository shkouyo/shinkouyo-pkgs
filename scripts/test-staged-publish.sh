#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

bin_dir="$tmp_dir/bin"
object_dir="$tmp_dir/objects"
aws_log="$tmp_dir/aws.log"
mkdir -p "$bin_dir" "$object_dir"
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
        while [ "$#" -gt 0 ]; do
            case $1 in
                --endpoint-url)
                    shift 2
                    ;;
                *)
                    break
                    ;;
            esac
        done
        [ "$#" -eq 2 ] || exit 2
        src=$1
        dest=$2
        printf 'cp %s %s\n' "$src" "$dest" >>"$TEST_AWS_LOG"
        case $src in
            s3://*)
                key=$(uri_key "$src")
                mkdir -p "$(dirname "$dest")"
                cp "$TEST_OBJECT_DIR/$key" "$dest"
                ;;
            *)
                key=$(uri_key "$dest")
                mkdir -p "$(dirname "$TEST_OBJECT_DIR/$key")"
                cp "$src" "$TEST_OBJECT_DIR/$key"
                ;;
        esac
        ;;
    s3:ls)
        shift 2
        while [ "$#" -gt 0 ]; do
            case $1 in
                --endpoint-url)
                    shift 2
                    ;;
                --recursive)
                    shift
                    ;;
                *)
                    break
                    ;;
            esac
        done
        [ "$#" -eq 1 ] || exit 2
        prefix=$(uri_key "$1")
        prefix=${prefix%/}
        if [ -d "$TEST_OBJECT_DIR/$prefix" ]; then
            find "$TEST_OBJECT_DIR/$prefix" -type f | LC_ALL=C sort |
                while IFS= read -r path; do
                    key=${path#"$TEST_OBJECT_DIR/"}
                    printf '2026-01-01 00:00:00 %s %s\n' "$(wc -c <"$path" | tr -d ' ')" "$key"
                done
        fi
        ;;
    s3:rm)
        shift 2
        recursive=0
        while [ "$#" -gt 0 ]; do
            case $1 in
                --endpoint-url)
                    shift 2
                    ;;
                --recursive)
                    recursive=1
                    shift
                    ;;
                *)
                    break
                    ;;
            esac
        done
        [ "$#" -eq 1 ] || exit 2
        key=$(uri_key "$1")
        printf 'rm %s recursive=%s\n' "$1" "$recursive" >>"$TEST_AWS_LOG"
        if [ "$recursive" -eq 1 ]; then
            rm -rf "$TEST_OBJECT_DIR/$key"
        else
            rm -f "$TEST_OBJECT_DIR/$key"
        fi
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

cat >"$bin_dir/repo-add" <<'EOF'
#!/bin/sh

set -eu

[ "$#" -ge 2 ] || exit 2
db_archive=$1
shift
files_archive=${db_archive%.db.tar.gz}.files.tar.gz
{
    printf 'repo-db\n'
    for pkgfile do
        printf '%s\n' "$pkgfile"
    done
} >"$db_archive"
cp "$db_archive" "$files_archive"
EOF
chmod +x "$bin_dir/repo-add"

cat >"$bin_dir/repo-remove" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$bin_dir/repo-remove"

make_context() {
    context_dir=$1
    package_file=$2

    mkdir -p "$context_dir/pkgdest"
    pkgpath="$context_dir/pkgdest/$package_file"
    printf '%s\n' "payload $package_file" >"$pkgpath"
    printf '%s\n' "signature $package_file" >"$pkgpath.sig"
    printf '%s\n' "$pkgpath" >"$context_dir/artifacts.list"
    cat >"$context_dir/state.env" <<EOF
STATE_VERSION=4
NAME='mpvpaper-rs'
SOURCE_GIT='https://aur.archlinux.org/mpvpaper-rs.git'
SOURCE_REF='master'
LAST_SOURCE_COMMIT='abcdef1234567890'
PKGNAMES='mpvpaper-rs'
PKGFILES='$package_file'
RECIPE_FINGERPRINT='recipe'
VCS_FINGERPRINT=''
PROBE_VERSION='vcs-probe-v9'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-source-heads-sha256-v1'
BUILT_AT='2026-01-01T00:00:00Z'
EOF
}

export PATH="$bin_dir:$PATH"
export TEST_OBJECT_DIR="$object_dir"
export TEST_AWS_LOG="$aws_log"
export REPO_NAME='repo-test'
export S3_BUCKET='repo-bucket'
export S3_ENDPOINT='https://example.invalid'
export S3_REGION='auto'

old_context="$tmp_dir/old-context"
new_context="$tmp_dir/new-context"
old_pkg='mpvpaper-rs-1-1-x86_64.pkg.tar.zst'
new_pkg='mpvpaper-rs-2-1-x86_64.pkg.tar.zst'

make_context "$old_context" "$old_pkg"
make_context "$new_context" "$new_pkg"

sh "$ROOT_DIR/scripts/stage.sh" "$old_context" 10-1
sh "$ROOT_DIR/scripts/stage.sh" "$new_context" 11-1

[ -f "$object_dir/.incoming/x86_64/mpvpaper-rs/10-1/ready" ] ||
    die 'stage did not upload old ready marker'
[ -f "$object_dir/.incoming/x86_64/mpvpaper-rs/11-1/ready" ] ||
    die 'stage did not upload new ready marker'

mkdir -p "$object_dir/.incoming/x86_64/deleted-pkg/12-1"
printf '%s\n' ready >"$object_dir/.incoming/x86_64/deleted-pkg/12-1/ready"

sh "$ROOT_DIR/scripts/publish-staged.sh"

[ -f "$object_dir/x86_64/$new_pkg" ] || die 'publisher did not upload latest package'
[ -f "$object_dir/x86_64/$new_pkg.sig" ] || die 'publisher did not upload latest signature'
[ ! -e "$object_dir/x86_64/$old_pkg" ] || die 'publisher uploaded stale package'
[ -f "$object_dir/.state/x86_64/mpvpaper-rs.env" ] || die 'publisher did not upload package state'
grep -F -x "PKGFILES='$new_pkg'" "$object_dir/.state/x86_64/mpvpaper-rs.env" >/dev/null ||
    die 'publisher uploaded wrong state'
[ ! -e "$object_dir/.incoming/x86_64/mpvpaper-rs/10-1" ] ||
    die 'publisher did not clean stale stage'
[ ! -e "$object_dir/.incoming/x86_64/mpvpaper-rs/11-1" ] ||
    die 'publisher did not clean published stage'
[ ! -e "$object_dir/.incoming/x86_64/deleted-pkg/12-1" ] ||
    die 'publisher did not clean removed package stage'

if grep -F 'max-parallel: 1' "$ROOT_DIR/.github/workflows/_check-updates.yml" >/dev/null; then
    die '_check-updates build matrix must not serialize package builds'
fi
if awk '
    /^  build:$/ { in_build = 1 }
    /^  publish:$/ { in_build = 0 }
    in_build && /max-parallel: 1/ { found = 1 }
    END { exit found ? 0 : 1 }
' "$ROOT_DIR/.github/workflows/reconcile-on-push.yml"; then
    die 'reconcile-on-push build matrix must not serialize package builds'
fi
if grep -F 'r2-write' "$ROOT_DIR/.github/workflows/_build-package.yml" >/dev/null; then
    die '_build-package must not hold the repo write lock'
fi

printf '%s\n' 'staged publish checks passed'
