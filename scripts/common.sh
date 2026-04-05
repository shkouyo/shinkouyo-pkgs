#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

ARCH='x86_64'
PKG_PREFIX="$ARCH"
STATE_PREFIX=".state/$ARCH"

log() {
    printf '%s\n' "$*" >&2
}

die() {
    log "error: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_env() {
    eval "value=\${$1-}"
    [ -n "$value" ] || die "missing env: $1"
}

require_runtime_env() {
    require_env GPG_PRIVATE_KEY
    require_env GPG_KEY_ID
    require_env REPO_NAME
    require_env S3_BUCKET
    require_env S3_ENDPOINT
    require_env S3_REGION
}

shell_quote() {
    escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$escaped"
}

repo_db_archive_name() {
    printf '%s.db.tar.gz' "$REPO_NAME"
}

repo_db_name() {
    printf '%s.db' "$REPO_NAME"
}

repo_files_archive_name() {
    printf '%s.files.tar.gz' "$REPO_NAME"
}

repo_files_name() {
    printf '%s.files' "$REPO_NAME"
}

repo_s3_uri() {
    printf 's3://%s/%s/%s' "$S3_BUCKET" "$PKG_PREFIX" "$1"
}

state_s3_uri() {
    printf 's3://%s/%s/%s' "$S3_BUCKET" "$STATE_PREFIX" "$1"
}

aws_s3_cp() {
    aws s3 cp --endpoint-url "$S3_ENDPOINT" "$@"
}

aws_s3_rm() {
    aws s3 rm --endpoint-url "$S3_ENDPOINT" "$@"
}

aws_s3_ls() {
    aws s3 ls --endpoint-url "$S3_ENDPOINT" "$@"
}

s3_object_exists() {
    key=$1
    aws s3api head-object \
        --endpoint-url "$S3_ENDPOINT" \
        --bucket "$S3_BUCKET" \
        --key "$key" >/dev/null 2>&1
}

ensure_repo_tools() {
    if command -v repo-add >/dev/null 2>&1 && command -v repo-remove >/dev/null 2>&1; then
        return 0
    fi
    command -v docker >/dev/null 2>&1 || die "repo-add/repo-remove unavailable and docker missing"
}

run_in_arch_tools() {
    ensure_repo_tools
    if [ "${1-}" = "--repo-mount" ]; then
        repo_mount=$2
        shift 2
    else
        repo_mount=$PWD
    fi
    if [ "${1-}" = "--extra-mount" ]; then
        extra_mount=$2
        shift 2
    else
        extra_mount=
    fi

    if command -v repo-add >/dev/null 2>&1 && command -v repo-remove >/dev/null 2>&1; then
        (cd "$repo_mount" && sh -eu -c "$*")
        return 0
    fi

    if [ -n "$extra_mount" ]; then
        docker run --rm \
            -v "$repo_mount:/repo" \
            -v "$ROOT_DIR:/workspace" \
            -v "$extra_mount:/extra" \
            -w /repo \
            archlinux:base-devel \
            sh -eu -c "pacman -Sy --noconfirm --needed pacman-contrib tar zstd >/dev/null && $*"
        return 0
    fi

    docker run --rm \
        -v "$repo_mount:/repo" \
        -v "$ROOT_DIR:/workspace" \
        -w /repo \
        archlinux:base-devel \
        sh -eu -c "pacman -Sy --noconfirm --needed pacman-contrib tar zstd >/dev/null && $*"
}

pkg_name_from_file() {
    pkgfile=$1

    if command -v bsdtar >/dev/null 2>&1; then
        name=$(bsdtar -xOf "$pkgfile" .PKGINFO 2>/dev/null | awk -F ' = ' '$1=="pkgname"{print $2; exit}')
        [ -n "$name" ] && {
            printf '%s\n' "$name"
            return 0
        }
    fi

    if command -v tar >/dev/null 2>&1 && command -v unzstd >/dev/null 2>&1; then
        name=$(tar --use-compress-program=unzstd -xOf "$pkgfile" .PKGINFO 2>/dev/null | awk -F ' = ' '$1=="pkgname"{print $2; exit}')
        [ -n "$name" ] && {
            printf '%s\n' "$name"
            return 0
        }
    fi

    command -v docker >/dev/null 2>&1 || die "cannot read package metadata from $pkgfile"
    pkgdir=$(dirname "$pkgfile")
    pkgbase=$(basename "$pkgfile")
    docker run --rm -v "$pkgdir:/mnt" archlinux:base-devel sh -eu -c \
        "pacman -Sy --noconfirm --needed tar zstd >/dev/null && tar --use-compress-program=unzstd -xOf /mnt/$pkgbase .PKGINFO | awk -F ' = ' '\$1==\"pkgname\"{print \$2; exit}'"
}

materialize_repo_links() {
    repo_dir=$1
    db_archive=$(repo_db_archive_name)
    files_archive=$(repo_files_archive_name)
    db_name=$(repo_db_name)
    files_name=$(repo_files_name)

    [ -f "$repo_dir/$db_archive" ] || return 0
    cp -f "$repo_dir/$db_archive" "$repo_dir/$db_name"
    [ -f "$repo_dir/$files_archive" ] && cp -f "$repo_dir/$files_archive" "$repo_dir/$files_name"
}

trim_package_basename() {
    basename "$1" .sh
}

is_template_manifest() {
    [ "$(basename "$1")" = "template.sh" ]
}
