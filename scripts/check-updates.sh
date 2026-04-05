#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$SCRIPT_DIR/manifest.sh"
. "$SCRIPT_DIR/state.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: check-updates.sh <all|regular|vcs>\n' >&2
    exit 1
}

mode=$1
case $mode in
    all|regular|vcs) ;;
    *) die "unsupported mode: $mode" ;;
esac

require_runtime_env
require_cmd git
require_cmd aws

packages_dir="$ROOT_DIR/packages"
[ -d "$packages_dir" ] || exit 0

for manifest in "$packages_dir"/*.sh; do
    [ -e "$manifest" ] || continue
    is_template_manifest "$manifest" && continue

    manifest_load "$manifest"
    [ "$UPDATE_ENABLED" = "1" ] || continue

    case $mode in
        regular)
            [ "$UPDATE_VCS" = "0" ] || continue
            ;;
        vcs)
            [ "$UPDATE_VCS" = "1" ] || continue
            ;;
    esac

    if [ "$UPDATE_VCS" = "1" ]; then
        printf '%s\n' "$NAME"
        continue
    fi

    manifest_source_git=$SOURCE_GIT
    manifest_source_ref=$SOURCE_REF
    tmp_dir=$(mktemp -d)
    state_file="$tmp_dir/$NAME.env"
    if ! state_download "$NAME" "$state_file" >/dev/null 2>&1; then
        printf '%s\n' "$NAME"
        rm -rf "$tmp_dir"
        continue
    fi

    state_load "$state_file"
    remote_line=$(git ls-remote "$manifest_source_git" "$manifest_source_ref" | awk 'NR==1{print $1}')
    [ -n "$remote_line" ] || die "failed to resolve remote ref for $NAME"
    if [ "$remote_line" != "$LAST_SOURCE_COMMIT" ]; then
        printf '%s\n' "$NAME"
    fi
    rm -rf "$tmp_dir"
done
