#!/bin/sh

set -eu

ARCH='x86_64'
PKG_PREFIX="$ARCH"
STATE_PREFIX=".state/$ARCH"
INCOMING_PREFIX=".incoming/$ARCH"

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

require_repo_env() {
    require_env REPO_NAME
    require_env S3_BUCKET
    require_env S3_ENDPOINT
    require_env S3_REGION
}

require_signing_env() {
    require_env GPG_PRIVATE_KEY
    require_env GPG_KEY_ID
}

require_publish_env() {
    require_repo_env
    require_signing_env
}

require_build_env() {
    require_publish_env
    require_env PACKAGER
}

require_update_env() {
    require_repo_env
}

require_probe_env() {
    require_update_env
    require_env PACKAGER
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

incoming_s3_uri() {
    printf 's3://%s/%s/%s' "$S3_BUCKET" "$INCOMING_PREFIX" "$1"
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

aws_s3_rm_recursive() {
    aws s3 rm --endpoint-url "$S3_ENDPOINT" --recursive "$@"
}

s3_list_keys() {
    prefix=$1
    list_tmp=$(mktemp)
    if ! aws_s3_ls --recursive "s3://$S3_BUCKET/$prefix/" >"$list_tmp"; then
        rm -f "$list_tmp"
        return 1
    fi
    awk '{ print $4 }' "$list_tmp"
    rm -f "$list_tmp"
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

    rm -f "$repo_dir/$db_name"
    cp -f "$repo_dir/$db_archive" "$repo_dir/$db_name"

    if [ -f "$repo_dir/$files_archive" ]; then
        rm -f "$repo_dir/$files_name"
        cp -f "$repo_dir/$files_archive" "$repo_dir/$files_name"
    fi
}

repo_download_existing_databases() {
    repo_dir=$1
    db_archive=$(repo_db_archive_name)
    files_archive=$(repo_files_archive_name)

    if s3_object_exists "$PKG_PREFIX/$db_archive"; then
        aws_s3_cp "$(repo_s3_uri "$db_archive")" "$repo_dir/$db_archive"
    fi
    if s3_object_exists "$PKG_PREFIX/$files_archive"; then
        aws_s3_cp "$(repo_s3_uri "$files_archive")" "$repo_dir/$files_archive"
    fi
}

repo_upload_databases() {
    repo_dir=$1
    db_archive=$(repo_db_archive_name)
    files_archive=$(repo_files_archive_name)
    db_name=$(repo_db_name)
    files_name=$(repo_files_name)

    [ -f "$repo_dir/$db_archive" ] || die "missing repo database: $repo_dir/$db_archive"
    [ -f "$repo_dir/$db_name" ] || die "missing repo database link: $repo_dir/$db_name"
    [ -f "$repo_dir/$files_archive" ] || die "missing repo files database: $repo_dir/$files_archive"
    [ -f "$repo_dir/$files_name" ] || die "missing repo files database link: $repo_dir/$files_name"

    aws_s3_cp "$repo_dir/$db_archive" "$(repo_s3_uri "$db_archive")"
    aws_s3_cp "$repo_dir/$db_name" "$(repo_s3_uri "$db_name")"
    aws_s3_cp "$repo_dir/$files_archive" "$(repo_s3_uri "$files_archive")"
    aws_s3_cp "$repo_dir/$files_name" "$(repo_s3_uri "$files_name")"
}

repo_delete_databases_if_present() {
    db_archive=$(repo_db_archive_name)
    files_archive=$(repo_files_archive_name)
    db_name=$(repo_db_name)
    files_name=$(repo_files_name)

    for object_name in "$db_archive" "$db_name" "$files_archive" "$files_name"; do
        if s3_object_exists "$PKG_PREFIX/$object_name"; then
            aws_s3_rm "$(repo_s3_uri "$object_name")"
        fi
    done
}

repo_pkgfile_pair_exists() {
    pkgfile=$1

    s3_object_exists "$PKG_PREFIX/$pkgfile" &&
        s3_object_exists "$PKG_PREFIX/$pkgfile.sig"
}

repo_pkgfiles_exist() {
    pkgfiles=$1

    for pkgfile in $pkgfiles; do
        repo_pkgfile_pair_exists "$pkgfile" || return 1
    done

    return 0
}

repo_delete_pkgfile_pair() {
    pkgfile=$1

    if s3_object_exists "$PKG_PREFIX/$pkgfile"; then
        aws_s3_rm "$(repo_s3_uri "$pkgfile")"
    fi
    if s3_object_exists "$PKG_PREFIX/$pkgfile.sig"; then
        aws_s3_rm "$(repo_s3_uri "$pkgfile.sig")"
    fi
}

trim_package_basename() {
    basename "$1" .sh
}

is_valid_package_name() {
    case ${1-} in
        ''|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789@._+-]*)
            return 1
            ;;
    esac
}

require_package_name() {
    is_valid_package_name "${1-}" || die "invalid package name: ${1-}"
}

is_valid_stage_id() {
    case ${1-} in
        ''|-*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
            return 1
            ;;
    esac
}

require_stage_id() {
    is_valid_stage_id "${1-}" || die "invalid stage id: ${1-}"
}

manifest_abs_path() {
    manifest_path=$1
    printf '%s/%s\n' "$(CDPATH= cd -- "$(dirname -- "$manifest_path")" && pwd)" "$(basename "$manifest_path")"
}
