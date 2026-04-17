#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

manifest_reset() {
    unset SCHEMA_VERSION NAME SOURCE_GIT SOURCE_REF BUILD_WORKDIR BUILD_PKGBUILD UPDATE_ENABLED UPDATE_VCS 2>/dev/null || :
    unset -f build_env 2>/dev/null || :
}

manifest_load() {
    manifest_path=$1
    [ -f "$manifest_path" ] || die "manifest not found: $manifest_path"

    manifest_reset
    # shellcheck disable=SC1090
    . "$manifest_path"

    [ "${SCHEMA_VERSION-}" = "1" ] || die "unsupported SCHEMA_VERSION in $manifest_path"
    [ -n "${NAME-}" ] || die "missing NAME in $manifest_path"
    [ -n "${SOURCE_GIT-}" ] || die "missing SOURCE_GIT in $manifest_path"
    [ -n "${SOURCE_REF-}" ] || die "missing SOURCE_REF in $manifest_path"
    [ -n "${BUILD_WORKDIR-}" ] || die "missing BUILD_WORKDIR in $manifest_path"
    [ -n "${BUILD_PKGBUILD-}" ] || die "missing BUILD_PKGBUILD in $manifest_path"
    [ -n "${UPDATE_ENABLED-}" ] || die "missing UPDATE_ENABLED in $manifest_path"
    [ -n "${UPDATE_VCS-}" ] || die "missing UPDATE_VCS in $manifest_path"
    case $UPDATE_ENABLED in
        0|1) ;;
        *) die "UPDATE_ENABLED must be 0 or 1 in $manifest_path" ;;
    esac
    case $UPDATE_VCS in
        0|1) ;;
        *) die "UPDATE_VCS must be 0 or 1 in $manifest_path" ;;
    esac

    expected_name=$(trim_package_basename "$manifest_path")
    [ "$NAME" = "$expected_name" ] || die "manifest NAME does not match filename: $manifest_path"
    command -v build_env >/dev/null 2>&1 || die "build_env() missing in $manifest_path"
}

manifest_emit_build_env() {
    baseline_file=$1
    result_file=$2

    env | LC_ALL=C sort >"$baseline_file"
    (
        build_env
        env | LC_ALL=C sort
    ) >"$result_file"
}

manifest_write_github_env() {
    output_file=$1
    base_file=$(mktemp)
    full_file=$(mktemp)
    trap 'rm -f "$base_file" "$full_file"' EXIT HUP INT TERM

    : >"$output_file"
    manifest_emit_build_env "$base_file" "$full_file"
    comm -13 "$base_file" "$full_file" | while IFS= read -r line; do
        case $line in
            _build_*=*)
                printf '%s\n' "$line" >>"$output_file"
                ;;
            ''|PWD=*|SHLVL=*|_*=*|OLDPWD=*|GITHUB_*|RUNNER_*|CI=*|HOME=*|PATH=*|LANG=*|LC_*=*|HOSTNAME=*|TERM=*|USER=*)
                ;;
            *=*)
                printf '%s\n' "$line" >>"$output_file"
                ;;
        esac
    done
}
