#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
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
PROBE_VERSION='vcs-probe-v3'

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

    require_build_env
    require_cmd git
    mkdir -p "$context_dir"
    context_dir=$(CDPATH= cd -- "$context_dir" && pwd)

    manifest_load "$manifest_path"
    is_template_manifest "$manifest_path" && die "template manifest is not buildable"

    source_dir="$context_dir/source"
    pkgdest_dir="$context_dir/pkgdest"
    rm -rf "$source_dir"
    mkdir -p "$pkgdest_dir"
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

    manifest_write_github_env "$context_dir/github.env"
    printf 'PKGDEST=%s\n' "$pkgdest_dir" >>"$context_dir/github.env"
    printf 'PACKAGER=%s\n' "$PACKAGER" >>"$context_dir/github.env"

    {
        printf 'MANIFEST_PATH=%s\n' "$(shell_quote "$(CDPATH= cd -- "$(dirname -- "$manifest_path")" && pwd)/$(basename "$manifest_path")")"
        printf 'NAME=%s\n' "$(shell_quote "$NAME")"
        printf 'SOURCE_GIT=%s\n' "$(shell_quote "$SOURCE_GIT")"
        printf 'SOURCE_REF=%s\n' "$(shell_quote "$SOURCE_REF")"
        printf 'SOURCE_DIR=%s\n' "$(shell_quote "$source_dir")"
        printf 'BUILD_DIR=%s\n' "$(shell_quote "$build_dir")"
        printf 'PKGDEST=%s\n' "$(shell_quote "$pkgdest_dir")"
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
    export PKGDEST PACKAGER
    makepkg --nobuild --nodeps --skipinteg -p "$BUILD_PKGBUILD" >/dev/null
}

run_probe_packagelist() {
    build_env
    export PKGDEST PACKAGER
    makepkg --packagelist --nodeps --skipinteg --holdver -p "$BUILD_PKGBUILD"
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

run_probe_attempt_makepkg() {
    strategy=$1

    (
        cd "$BUILD_DIR"
        case $strategy in
            packagelist)
                run_probe_packagelist
                ;;
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

    require_cmd makepkg

    log "probe[$PROBE_VERSION]: backend=makepkg package=$NAME strategy=$strategy"
    if ! run_probe_attempt_makepkg "$strategy"; then
        return 1
    fi

    cat "$probe_stdout_file" "$probe_stderr_file" >"$raw_pkglist_file"
    probe_extract_pkgfiles "$raw_pkglist_file" "$predicted_pkgfiles_file"

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
    if ! run_probe_attempt packagelist; then
        print_log_tail "probe[$PROBE_VERSION]: packagelist stdout for $NAME" "$probe_stdout_file"
        print_log_tail "probe[$PROBE_VERSION]: packagelist stderr for $NAME" "$probe_stderr_file"
        log "probe[$PROBE_VERSION]: primary strategy failed for $NAME, retrying with nobuild-packagelist"
    else
        current_predicted_pkgfiles=$(awk 'NF { print; exit }' "$predicted_pkgfiles_file")
        if [ -n "$current_predicted_pkgfiles" ]; then
            return 0
        fi

        print_log_tail "probe[$PROBE_VERSION]: packagelist stdout for $NAME" "$probe_stdout_file"
        print_log_tail "probe[$PROBE_VERSION]: packagelist stderr for $NAME" "$probe_stderr_file"
        log "probe[$PROBE_VERSION]: primary strategy produced no package files for $NAME, retrying with nobuild-packagelist"
    fi

    if ! run_probe_attempt nobuild-packagelist; then
        print_log_tail "probe[$PROBE_VERSION]: fallback stdout for $NAME" "$probe_stdout_file"
        print_log_tail "probe[$PROBE_VERSION]: fallback stderr for $NAME" "$probe_stderr_file"
        die "probe did not predict any package files for $NAME"
    fi

    current_predicted_pkgfiles=$(awk 'NF { print; exit }' "$predicted_pkgfiles_file")
    if [ -z "$current_predicted_pkgfiles" ]; then
        print_log_tail "probe[$PROBE_VERSION]: fallback stdout for $NAME" "$probe_stdout_file"
        print_log_tail "probe[$PROBE_VERSION]: fallback stderr for $NAME" "$probe_stderr_file"
        die "probe did not predict any package files for $NAME"
    fi
}

collect() {
    context_dir=$1
    require_runtime_env
    require_cmd gpg

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
    VCS_FINGERPRINT=''
    export NAME SOURCE_GIT SOURCE_REF LAST_SOURCE_COMMIT PKGNAMES PKGFILES VCS_FINGERPRINT BUILT_AT
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
