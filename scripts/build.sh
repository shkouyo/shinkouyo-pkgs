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
  build.sh seed-vcs-fingerprint <context_dir>
  build.sh collect <context_dir>
EOF
    exit 1
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

vcs_fingerprint_from_srcdir() {
    srcdir_path=$1
    [ -d "$srcdir_path" ] || {
        printf '\n'
        return 0
    }

    tmp_file=$(mktemp)

    find "$srcdir_path" \( -name .git -o -name .hg -o -name .svn -o -name .fslckout -o -name .bzr \) | while IFS= read -r marker; do
        [ -n "$marker" ] || continue
        checkout_dir=$(dirname "$marker")
        rel_dir=${checkout_dir#"$srcdir_path"/}
        [ "$checkout_dir" = "$srcdir_path" ] && rel_dir='.'

        case $(basename "$marker") in
            .git)
                require_cmd git
                revision=$(git -C "$checkout_dir" rev-parse HEAD 2>/dev/null) || die "failed to resolve git revision for $checkout_dir"
                printf 'git:%s:%s\n' "$rel_dir" "$revision" >>"$tmp_file"
                ;;
            .hg)
                require_cmd hg
                revision=$(hg -R "$checkout_dir" id -i 2>/dev/null) || die "failed to resolve hg revision for $checkout_dir"
                revision=${revision%%+}
                printf 'hg:%s:%s\n' "$rel_dir" "$revision" >>"$tmp_file"
                ;;
            .svn)
                require_cmd svn
                revision=$(svn info --show-item revision "$checkout_dir" 2>/dev/null) || die "failed to resolve svn revision for $checkout_dir"
                printf 'svn:%s:%s\n' "$rel_dir" "$revision" >>"$tmp_file"
                ;;
            .fslckout)
                require_cmd fossil
                revision=$(fossil info -R "$marker" 2>/dev/null | awk '/^checkout:/ {print $2; exit}') || die "failed to resolve fossil revision for $checkout_dir"
                [ -n "$revision" ] || die "failed to parse fossil revision for $checkout_dir"
                printf 'fossil:%s:%s\n' "$rel_dir" "$revision" >>"$tmp_file"
                ;;
            .bzr)
                require_cmd bzr
                revision=$(bzr revno "$checkout_dir" 2>/dev/null) || die "failed to resolve bzr revision for $checkout_dir"
                printf 'bzr:%s:%s\n' "$rel_dir" "$revision" >>"$tmp_file"
                ;;
        esac
    done

    if [ -s "$tmp_file" ]; then
        LC_ALL=C sort -u "$tmp_file" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
    else
        printf '\n'
    fi
    rm -f "$tmp_file"
}

run_probe_makepkg() {
    build_env
    export PKGDEST PACKAGER
    makepkg --nobuild --nodeps --skipinteg -p "$BUILD_PKGBUILD" >/dev/null
}

run_probe_makepkg_in_container() {
    command -v docker >/dev/null 2>&1 || die "probe-vcs requires either makepkg or docker"

    docker run --rm \
        -v "$ROOT_DIR:$ROOT_DIR" \
        -v "$context_dir:$context_dir" \
        -w "$BUILD_DIR" \
        archlinux:multilib-devel \
        sh -eu -c \
        ". \"$context_dir/context.env\"; . \"$MANIFEST_PATH\"; build_env; export PKGDEST PACKAGER; makepkg --nobuild --nodeps --skipinteg -p \"\$BUILD_PKGBUILD\" >/dev/null"
}

write_vcs_fingerprint() {
    vcs_fingerprint_file=$1
    vcs_fingerprint=$(vcs_fingerprint_from_srcdir "$BUILD_DIR/src")
    printf '%s\n' "$vcs_fingerprint" >"$vcs_fingerprint_file"
}

seed_vcs_fingerprint() {
    context_dir=$1
    # shellcheck disable=SC1090
    . "$context_dir/context.env"
    # shellcheck disable=SC1090
    . "$MANIFEST_PATH"

    vcs_fingerprint_file="$context_dir/vcs_fingerprint.txt"
    : >"$vcs_fingerprint_file"
    [ "${UPDATE_VCS:-0}" = "1" ] || return 0

    (
        cd "$BUILD_DIR"
        if command -v makepkg >/dev/null 2>&1; then
            run_probe_makepkg
        else
            run_probe_makepkg_in_container
        fi
    )

    write_vcs_fingerprint "$vcs_fingerprint_file"
    current_vcs_fingerprint=$(awk 'NF { print; exit }' "$vcs_fingerprint_file")
    [ -n "$current_vcs_fingerprint" ] || die "failed to determine vcs fingerprint for $NAME"
}

probe_vcs() {
    manifest_path=$1
    context_dir=$2

    prepare_context "$manifest_path" "$context_dir"
    seed_vcs_fingerprint "$context_dir"
}

collect() {
    context_dir=$1
    require_runtime_env
    require_cmd gpg

    # shellcheck disable=SC1090
    . "$context_dir/context.env"
    # shellcheck disable=SC1090
    . "$MANIFEST_PATH"

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
    if [ "${UPDATE_VCS:-0}" = "1" ]; then
        vcs_fingerprint_file="$context_dir/vcs_fingerprint.txt"
        if [ -f "$vcs_fingerprint_file" ]; then
            VCS_FINGERPRINT=$(awk 'NF { print; exit }' "$vcs_fingerprint_file")
        fi
        if [ -z "$VCS_FINGERPRINT" ]; then
            VCS_FINGERPRINT=$(vcs_fingerprint_from_srcdir "$BUILD_DIR/src")
        fi
        [ -n "$VCS_FINGERPRINT" ] || die "missing vcs fingerprint for $NAME"
    fi
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
    seed-vcs-fingerprint)
        [ "$#" -eq 2 ] || usage
        seed_vcs_fingerprint "$2"
        ;;
    collect)
        [ "$#" -eq 2 ] || usage
        collect "$2"
        ;;
    *)
        usage
        ;;
esac
