#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/manifest.sh"
. "$SCRIPT_DIR/state.sh"

usage() {
    cat >&2 <<'EOF'
usage:
  build.sh prepare <manifest> <context_dir>
  build.sh probe-vcs <manifest> <context_dir>
  build.sh collect <context_dir>
EOF
    exit 1
}

PROBE_LOG_TAIL_LINES=50
PROBE_VERSION='vcs-probe-v7'

print_log_tail() {
    label=$1
    file=$2

    [ -f "$file" ] || return 0
    [ -s "$file" ] || return 0

    log "$label (last $PROBE_LOG_TAIL_LINES lines):"
    tail -n "$PROBE_LOG_TAIL_LINES" "$file" >&2
}

prepare_context() {
    manifest_path=$1
    context_dir=$2

    require_probe_env
    require_cmd git
    mkdir -p "$context_dir"
    context_dir=$(CDPATH= cd -- "$context_dir" && pwd)

    manifest_load "$manifest_path"

    source_dir="$context_dir/source"
    pkgdest_dir="$context_dir/pkgdest"
    srcdest_dir="$context_dir/srcdest"
    makepkg_builddir="$context_dir/makepkg-builddir"
    rm -rf "$source_dir" "$makepkg_builddir"
    mkdir -p "$pkgdest_dir" "$srcdest_dir" "$makepkg_builddir"
    git clone --filter=blob:none "$SOURCE_GIT" "$source_dir"
    (
        cd "$source_dir"
        resolved_commit=''
        if resolved_commit=$(git rev-parse --verify "${SOURCE_REF}^{commit}" 2>/dev/null); then
            :
        elif resolved_commit=$(git rev-parse --verify "origin/${SOURCE_REF}^{commit}" 2>/dev/null); then
            :
        else
            die "failed to resolve SOURCE_REF to a commit: $SOURCE_REF"
        fi
        git checkout --detach "$resolved_commit"
        printf '%s\n' "$resolved_commit" >"$context_dir/last_source_commit.txt"
    )

    build_dir="$source_dir/$BUILD_WORKDIR"
    [ -d "$build_dir" ] || die "BUILD_WORKDIR not found: $BUILD_WORKDIR"
    [ -f "$source_dir/$BUILD_PKGBUILD" ] || die "BUILD_PKGBUILD not found: $BUILD_PKGBUILD"

    # The Arch build action runs as an unprivileged container user against the
    # runner temp mount, so the prepared tree must be writable by that user.
    chmod -R a+rwX "$source_dir"
    chmod -R a+rwX "$pkgdest_dir"
    chmod -R a+rwX "$srcdest_dir"
    chmod -R a+rwX "$makepkg_builddir"

    manifest_write_github_env "$context_dir/github.env"
    printf 'PKGDEST=%s\n' "$pkgdest_dir" >>"$context_dir/github.env"
    printf 'SRCDEST=%s\n' "$srcdest_dir" >>"$context_dir/github.env"
    printf 'BUILDDIR=%s\n' "$makepkg_builddir" >>"$context_dir/github.env"
    printf 'PACKAGER=%s\n' "$PACKAGER" >>"$context_dir/github.env"

    {
        printf 'MANIFEST_PATH=%s\n' "$(shell_quote "$(manifest_abs_path "$manifest_path")")"
        printf 'NAME=%s\n' "$(shell_quote "$NAME")"
        printf 'SOURCE_GIT=%s\n' "$(shell_quote "$SOURCE_GIT")"
        printf 'SOURCE_REF=%s\n' "$(shell_quote "$SOURCE_REF")"
        printf 'SOURCE_DIR=%s\n' "$(shell_quote "$source_dir")"
        printf 'BUILD_DIR=%s\n' "$(shell_quote "$build_dir")"
        printf 'MAKEPKG_BUILDDIR=%s\n' "$(shell_quote "$makepkg_builddir")"
        printf 'PKGDEST=%s\n' "$(shell_quote "$pkgdest_dir")"
        printf 'SRCDEST=%s\n' "$(shell_quote "$srcdest_dir")"
        printf 'PACKAGER=%s\n' "$(shell_quote "$PACKAGER")"
        printf 'BUILD_PKGBUILD=%s\n' "$(shell_quote "$BUILD_PKGBUILD")"
        printf 'LAST_SOURCE_COMMIT=%s\n' "$(shell_quote "$(cat "$context_dir/last_source_commit.txt")")"
    } >"$context_dir/context.env"
}

prepare() {
    prepare_context "$1" "$2"
}

run_probe_nobuild() {
    build_env
    BUILDDIR=${BUILDDIR:-${MAKEPKG_BUILDDIR-}}
    export PKGDEST SRCDEST PACKAGER BUILDDIR
    makepkg --nobuild --nodeps --skipinteg --nosign -p "$BUILD_PKGBUILD" >/dev/null
}

run_probe_packagelist() {
    build_env
    BUILDDIR=${BUILDDIR:-${MAKEPKG_BUILDDIR-}}
    export PKGDEST SRCDEST PACKAGER BUILDDIR
    makepkg --packagelist --nodeps --skipinteg --holdver --nosign -p "$BUILD_PKGBUILD"
}

file_sha256() {
    sha256sum "$1" | awk '{ print $1 }'
}

probe_extract_pkgfiles() {
    input_file=$1
    output_file=$2

    while IFS= read -r pkgpath; do
        [ -n "$pkgpath" ] || continue
        case $pkgpath in
            *.pkg.tar|*.pkg.tar.*) ;;
            *) continue ;;
        esac
        basename "$pkgpath"
    done <"$input_file" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' >"$output_file"
}

append_git_repo_fingerprint() {
    fingerprint_scan_root=$1
    fingerprint_repo_dir=$2
    fingerprint_output_file=$3

    case $fingerprint_repo_dir in
        "$fingerprint_scan_root")
            fingerprint_rel=.
            ;;
        "$fingerprint_scan_root"/*)
            fingerprint_rel=${fingerprint_repo_dir#"$fingerprint_scan_root"/}
            ;;
        *)
            fingerprint_rel=$fingerprint_repo_dir
            ;;
    esac

    fingerprint_commit=$(git -C "$fingerprint_repo_dir" rev-parse --verify HEAD 2>/dev/null) || return 0
    printf '%s HEAD %s\n' "$fingerprint_rel" "$fingerprint_commit" >>"$fingerprint_output_file"
}

write_vcs_fingerprint_root() {
    fingerprint_root=$1
    fingerprint_root_output_file=$2

    [ -d "$fingerprint_root" ] || return 0

    fingerprint_root_tmp_file=$(mktemp)
    : >"$fingerprint_root_tmp_file"

    find "$fingerprint_root" -name .git -print -prune | while IFS= read -r fingerprint_git_meta; do
        fingerprint_repo_dir=$(dirname "$fingerprint_git_meta")
        append_git_repo_fingerprint "$fingerprint_root" "$fingerprint_repo_dir" "$fingerprint_root_tmp_file"
    done

    LC_ALL=C sort -u "$fingerprint_root_tmp_file" >>"$fingerprint_root_output_file"
    rm -f "$fingerprint_root_tmp_file"
}

write_vcs_fingerprint_makepkg_builddir() {
    fingerprint_makepkg_builddir=$1
    fingerprint_makepkg_output_file=$2

    [ -d "$fingerprint_makepkg_builddir" ] || return 0

    for fingerprint_package_dir in "$fingerprint_makepkg_builddir"/*; do
        [ -d "$fingerprint_package_dir/src" ] || continue
        write_vcs_fingerprint_root "$fingerprint_package_dir/src" "$fingerprint_makepkg_output_file"
    done
}

write_vcs_fingerprint_details() {
    fingerprint_details_output_file=$1

    fingerprint_details_tmp_file=$(mktemp)
    : >"$fingerprint_details_tmp_file"
    write_vcs_fingerprint_root "$BUILD_DIR/src" "$fingerprint_details_tmp_file"
    if [ -n "${MAKEPKG_BUILDDIR-}" ]; then
        write_vcs_fingerprint_makepkg_builddir "$MAKEPKG_BUILDDIR" "$fingerprint_details_tmp_file"
    fi
    if [ -n "${BUILDDIR-}" ] && [ "$BUILDDIR" != "${MAKEPKG_BUILDDIR-}" ]; then
        write_vcs_fingerprint_makepkg_builddir "$BUILDDIR" "$fingerprint_details_tmp_file"
    fi
    LC_ALL=C sort -u "$fingerprint_details_tmp_file" >"$fingerprint_details_output_file"
    rm -f "$fingerprint_details_tmp_file"
}

write_vcs_fingerprint() {
    fingerprint_hash_output_file=$1

    fingerprint_hash_detail_file=$(mktemp)
    write_vcs_fingerprint_details "$fingerprint_hash_detail_file"
    if [ -s "$fingerprint_hash_detail_file" ]; then
        file_sha256 "$fingerprint_hash_detail_file" >"$fingerprint_hash_output_file"
    else
        : >"$fingerprint_hash_output_file"
    fi
    rm -f "$fingerprint_hash_detail_file"
}

write_recipe_fingerprint() {
    recipe_output_file=$1

    recipe_tmp_file=$(mktemp)
    : >"$recipe_tmp_file"
    (
        cd "$BUILD_DIR"
        find . \
            \( -path './.git' -o -path './.git/*' \
            -o -path './src' -o -path './src/*' \
            -o -path './pkg' -o -path './pkg/*' \
            -o -name '.SRCINFO' \
            -o -name '*.pkg.tar' -o -name '*.pkg.tar.*' \) -prune \
            -o -type f -print |
            LC_ALL=C sort |
            while IFS= read -r recipe_file; do
                [ -n "$recipe_file" ] || continue
                printf '%s %s\n' "$(file_sha256 "$recipe_file")" "$recipe_file"
            done
    ) >"$recipe_tmp_file"

    file_sha256 "$recipe_tmp_file" >"$recipe_output_file"
    rm -f "$recipe_tmp_file"
}

run_probe_attempt_makepkg() {
    strategy=$1

    (
        cd "$BUILD_DIR"
        case $strategy in
            nobuild-packagelist)
                run_probe_nobuild
                run_probe_packagelist
                ;;
            *)
                die "unsupported probe strategy: $strategy"
                ;;
        esac
    ) >"$probe_stdout_file" 2>"$probe_stderr_file"
}

run_probe_attempt() {
    strategy=$1

    : >"$probe_stdout_file"
    : >"$probe_stderr_file"
    : >"$raw_pkglist_file"
    : >"$predicted_pkgfiles_file"
    : >"$vcs_fingerprint_file"

    require_cmd makepkg
    require_cmd git
    require_cmd sha256sum

    log "probe[$PROBE_VERSION]: backend=makepkg package=$NAME strategy=$strategy"
    if ! run_probe_attempt_makepkg "$strategy"; then
        return 1
    fi

    cat "$probe_stdout_file" "$probe_stderr_file" >"$raw_pkglist_file"
    probe_extract_pkgfiles "$raw_pkglist_file" "$predicted_pkgfiles_file"
    write_vcs_fingerprint "$vcs_fingerprint_file"

    [ -n "$(awk 'NF { print; exit }' "$predicted_pkgfiles_file")" ]
}

probe_vcs() {
    manifest_path=$1
    context_dir=$2

    prepare_context "$manifest_path" "$context_dir"
    # shellcheck disable=SC1090
    . "$context_dir/context.env"

    predicted_pkgfiles_file="$context_dir/predicted_pkgfiles.txt"
    probe_stdout_file="$context_dir/predicted_pkgfiles.stdout"
    probe_stderr_file="$context_dir/predicted_pkgfiles.stderr"
    raw_pkglist_file="$context_dir/predicted_pkgfiles.raw"
    recipe_fingerprint_file="$context_dir/recipe_fingerprint.txt"
    vcs_fingerprint_file="$context_dir/vcs_fingerprint.txt"
    vcs_fingerprint_details_file="$context_dir/vcs_fingerprint.details"
    if ! run_probe_attempt nobuild-packagelist; then
        print_log_tail "probe[$PROBE_VERSION]: nobuild-packagelist stdout for $NAME" "$probe_stdout_file"
        print_log_tail "probe[$PROBE_VERSION]: nobuild-packagelist stderr for $NAME" "$probe_stderr_file"
        die "probe did not predict any package files for $NAME"
    fi

    current_predicted_pkgfiles=$(awk 'NF { print; exit }' "$predicted_pkgfiles_file")
    if [ -z "$current_predicted_pkgfiles" ]; then
        print_log_tail "probe[$PROBE_VERSION]: nobuild-packagelist stdout for $NAME" "$probe_stdout_file"
        print_log_tail "probe[$PROBE_VERSION]: nobuild-packagelist stderr for $NAME" "$probe_stderr_file"
        die "probe did not predict any package files for $NAME"
    fi

    write_recipe_fingerprint "$recipe_fingerprint_file"
    write_vcs_fingerprint_details "$vcs_fingerprint_details_file"
    if [ -s "$vcs_fingerprint_details_file" ]; then
        file_sha256 "$vcs_fingerprint_details_file" >"$vcs_fingerprint_file"
    else
        : >"$vcs_fingerprint_file"
    fi
}

collect() {
    context_dir=$1
    require_publish_env
    require_cmd gpg
    require_cmd git
    require_cmd sha256sum

    # shellcheck disable=SC1090
    . "$context_dir/context.env"

    artifact_list_file="$context_dir/artifacts.list"
    : >"$artifact_list_file"
    if [ -n "${PKGDEST-}" ] && [ -d "$PKGDEST" ]; then
        find "$PKGDEST" -type f -name '*.pkg.tar.zst' | LC_ALL=C sort >"$artifact_list_file"
    fi
    if [ ! -s "$artifact_list_file" ]; then
        find "$SOURCE_DIR" -type f -name '*.pkg.tar.zst' | LC_ALL=C sort >"$artifact_list_file"
    fi
    [ -s "$artifact_list_file" ] || die "no built package artifacts found in ${PKGDEST:-$SOURCE_DIR}"

    export GNUPGHOME="$context_dir/gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1

    pkgfiles=''
    pkgnames=''
    while IFS= read -r pkgfile; do
        [ -n "$pkgfile" ] || continue
        gpg --batch --yes --detach-sign --local-user "$GPG_KEY_ID" "$pkgfile"
        base=$(basename "$pkgfile")
        name=$(pkg_name_from_file "$pkgfile")
        [ -n "$name" ] || die "failed to extract pkgname from $pkgfile"
        pkgfiles="${pkgfiles}${pkgfiles:+ }$base"
        case " $pkgnames " in
            *" $name "*) ;;
            *) pkgnames="${pkgnames}${pkgnames:+ }$name" ;;
        esac
    done <"$artifact_list_file"

    LAST_SOURCE_COMMIT=$(cat "$context_dir/last_source_commit.txt")
    BUILT_AT=$(date -u +%FT%TZ)
    PKGNAMES=$pkgnames
    PKGFILES=$pkgfiles
    recipe_fingerprint_file="$context_dir/recipe_fingerprint.txt"
    write_recipe_fingerprint "$recipe_fingerprint_file"
    RECIPE_FINGERPRINT=$(cat "$recipe_fingerprint_file")
    fingerprint_file="$context_dir/vcs_fingerprint.txt"
    write_vcs_fingerprint "$fingerprint_file"
    VCS_FINGERPRINT=$(cat "$fingerprint_file")
    export NAME SOURCE_GIT SOURCE_REF LAST_SOURCE_COMMIT PKGNAMES PKGFILES RECIPE_FINGERPRINT VCS_FINGERPRINT BUILT_AT
    state_write_file "$context_dir/state.env"
}

cmd=${1-}
case $cmd in
    prepare)
        [ "$#" -eq 3 ] || usage
        prepare "$2" "$3"
        ;;
    probe-vcs)
        [ "$#" -eq 3 ] || usage
        probe_vcs "$2" "$3"
        ;;
    collect)
        [ "$#" -eq 2 ] || usage
        collect "$2"
        ;;
    *)
        usage
        ;;
esac
