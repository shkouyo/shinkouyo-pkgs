#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

state_relpath() {
    printf '%s/%s.env' "$STATE_PREFIX" "$1"
}

state_local_path() {
    base_dir=$1
    name=$2
    printf '%s/%s.env' "$base_dir" "$name"
}

state_write_file() {
    output_file=$1
    {
        printf 'STATE_VERSION=2\n'
        printf 'NAME=%s\n' "$(shell_quote "$NAME")"
        printf 'SOURCE_GIT=%s\n' "$(shell_quote "$SOURCE_GIT")"
        printf 'SOURCE_REF=%s\n' "$(shell_quote "$SOURCE_REF")"
        printf 'LAST_SOURCE_COMMIT=%s\n' "$(shell_quote "$LAST_SOURCE_COMMIT")"
        printf 'PKGNAMES=%s\n' "$(shell_quote "$PKGNAMES")"
        printf 'PKGFILES=%s\n' "$(shell_quote "$PKGFILES")"
        printf 'VCS_FINGERPRINT=%s\n' "$(shell_quote "${VCS_FINGERPRINT-}")"
        printf 'BUILT_AT=%s\n' "$(shell_quote "$BUILT_AT")"
    } >"$output_file"
}

state_load() {
    state_file=$1
    [ -f "$state_file" ] || die "state not found: $state_file"

    unset STATE_VERSION NAME SOURCE_GIT SOURCE_REF LAST_SOURCE_COMMIT PKGNAMES PKGFILES VCS_FINGERPRINT BUILT_AT 2>/dev/null || :
    # shellcheck disable=SC1090
    . "$state_file"

    case "${STATE_VERSION-}" in
        1)
            : "${VCS_FINGERPRINT:=}"
            ;;
        2)
            [ -n "${VCS_FINGERPRINT+x}" ] || die "missing VCS_FINGERPRINT in $state_file"
            ;;
        *)
            die "unsupported STATE_VERSION in $state_file"
            ;;
    esac
    [ -n "${NAME-}" ] || die "missing NAME in $state_file"
    [ -n "${SOURCE_GIT-}" ] || die "missing SOURCE_GIT in $state_file"
    [ -n "${SOURCE_REF-}" ] || die "missing SOURCE_REF in $state_file"
    [ -n "${LAST_SOURCE_COMMIT-}" ] || die "missing LAST_SOURCE_COMMIT in $state_file"
    [ -n "${PKGNAMES-}" ] || die "missing PKGNAMES in $state_file"
    [ -n "${PKGFILES-}" ] || die "missing PKGFILES in $state_file"
    [ -n "${BUILT_AT-}" ] || die "missing BUILT_AT in $state_file"
}

state_emit_prefixed() {
    prefix=$1
    state_file=$2

    (
        state_load "$state_file"
        printf '%s_NAME=%s\n' "$prefix" "$(shell_quote "$NAME")"
        printf '%s_SOURCE_GIT=%s\n' "$prefix" "$(shell_quote "$SOURCE_GIT")"
        printf '%s_SOURCE_REF=%s\n' "$prefix" "$(shell_quote "$SOURCE_REF")"
        printf '%s_LAST_SOURCE_COMMIT=%s\n' "$prefix" "$(shell_quote "$LAST_SOURCE_COMMIT")"
        printf '%s_PKGNAMES=%s\n' "$prefix" "$(shell_quote "$PKGNAMES")"
        printf '%s_PKGFILES=%s\n' "$prefix" "$(shell_quote "$PKGFILES")"
        printf '%s_VCS_FINGERPRINT=%s\n' "$prefix" "$(shell_quote "${VCS_FINGERPRINT-}")"
        printf '%s_BUILT_AT=%s\n' "$prefix" "$(shell_quote "$BUILT_AT")"
    )
}

state_download() {
    name=$1
    dest=$2
    aws_s3_cp "$(state_s3_uri "$name.env")" "$dest"
}

state_upload() {
    name=$1
    src=$2
    aws_s3_cp "$src" "$(state_s3_uri "$name.env")"
}

state_delete_remote() {
    name=$1
    aws_s3_rm "$(state_s3_uri "$name.env")"
}
