#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$SCRIPT_DIR/manifest.sh"
. "$SCRIPT_DIR/state.sh"

usage() {
    cat >&2 <<'EOF'
usage:
  build.sh prepare <manifest> <context_dir>
  build.sh collect <context_dir>
EOF
    exit 1
}

prepare() {
    manifest_path=$1
    context_dir=$2

    require_cmd git
    mkdir -p "$context_dir"
    context_dir=$(CDPATH= cd -- "$context_dir" && pwd)

    manifest_load "$manifest_path"
    is_template_manifest "$manifest_path" && die "template manifest is not buildable"

    source_dir="$context_dir/source"
    rm -rf "$source_dir"
    git clone --filter=blob:none "$SOURCE_GIT" "$source_dir"
    (
        cd "$source_dir"
        git checkout --detach "$SOURCE_REF"
        resolved_commit=$(git rev-parse HEAD)
        printf '%s\n' "$resolved_commit" >"$context_dir/last_source_commit.txt"
    )

    build_dir="$source_dir/$BUILD_WORKDIR"
    [ -d "$build_dir" ] || die "BUILD_WORKDIR not found: $BUILD_WORKDIR"
    [ -f "$source_dir/$BUILD_PKGBUILD" ] || die "BUILD_PKGBUILD not found: $BUILD_PKGBUILD"

    # The Arch build action runs as an unprivileged container user against the
    # runner temp mount, so the prepared tree must be writable by that user.
    chmod -R a+rwX "$source_dir"

    manifest_write_github_env "$context_dir/github.env"

    {
        printf 'MANIFEST_PATH=%s\n' "$(shell_quote "$(CDPATH= cd -- "$(dirname -- "$manifest_path")" && pwd)/$(basename "$manifest_path")")"
        printf 'NAME=%s\n' "$(shell_quote "$NAME")"
        printf 'SOURCE_GIT=%s\n' "$(shell_quote "$SOURCE_GIT")"
        printf 'SOURCE_REF=%s\n' "$(shell_quote "$SOURCE_REF")"
        printf 'SOURCE_DIR=%s\n' "$(shell_quote "$source_dir")"
        printf 'BUILD_DIR=%s\n' "$(shell_quote "$build_dir")"
        printf 'BUILD_PKGBUILD=%s\n' "$(shell_quote "$BUILD_PKGBUILD")"
        printf 'LAST_SOURCE_COMMIT=%s\n' "$(shell_quote "$(cat "$context_dir/last_source_commit.txt")")"
    } >"$context_dir/context.env"
}

collect() {
    context_dir=$1
    require_runtime_env
    require_cmd gpg

    # shellcheck disable=SC1090
    . "$context_dir/context.env"

    artifact_list_file="$context_dir/artifacts.list"
    : >"$artifact_list_file"
    find "$SOURCE_DIR" -type f -name '*.pkg.tar.zst' | LC_ALL=C sort >"$artifact_list_file"
    [ -s "$artifact_list_file" ] || die "no built package artifacts found in $SOURCE_DIR"

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
    export NAME SOURCE_GIT SOURCE_REF LAST_SOURCE_COMMIT PKGNAMES PKGFILES BUILT_AT
    state_write_file "$context_dir/state.env"
}

cmd=${1-}
case $cmd in
    prepare)
        [ "$#" -eq 3 ] || usage
        prepare "$2" "$3"
        ;;
    collect)
        [ "$#" -eq 2 ] || usage
        collect "$2"
        ;;
    *)
        usage
        ;;
esac
