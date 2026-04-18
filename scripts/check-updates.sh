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

queue_package() {
    printf '%s\n' "$1"
}

check_regular_package() {
    manifest_source_git=$SOURCE_GIT
    manifest_source_ref=$SOURCE_REF
    tmp_dir=$1
    state_file="$tmp_dir/$NAME.env"

    if ! state_download "$NAME" "$state_file" >/dev/null 2>&1; then
        log "$NAME: missing state, queued"
        queue_package "$NAME"
        return 0
    fi

    state_load "$state_file"
    remote_line=$(git ls-remote "$manifest_source_git" "$manifest_source_ref" | awk 'NR==1{print $1}')
    [ -n "$remote_line" ] || die "failed to resolve remote ref for $NAME"
    if [ "$remote_line" != "$LAST_SOURCE_COMMIT" ]; then
        log "$NAME: source commit changed, queued"
        queue_package "$NAME"
        return 0
    fi

    log "$NAME: unchanged, skipped"
}

check_vcs_package() {
    manifest_path=$1
    tmp_dir=$2
    state_file="$tmp_dir/$NAME.env"

    if ! state_download "$NAME" "$state_file" >/dev/null 2>&1; then
        log "$NAME: missing state, queued"
        queue_package "$NAME"
        return 0
    fi

    state_load "$state_file"
    previous_pkgfiles=$PKGFILES

    remote_line=$(git ls-remote "$SOURCE_GIT" "$SOURCE_REF" | awk 'NR==1{print $1}')
    [ -n "$remote_line" ] || die "failed to resolve remote ref for $NAME"
    if [ "$remote_line" != "$LAST_SOURCE_COMMIT" ]; then
        log "$NAME: source commit changed, queued"
        queue_package "$NAME"
        return 0
    fi

    probe_dir="$tmp_dir/probe"
    mkdir -p "$probe_dir"
    if ! "$SCRIPT_DIR/build.sh" probe-vcs "$manifest_path" "$probe_dir" >/dev/null 2>&1; then
        log "$NAME: probe failed, queued"
        queue_package "$NAME"
        return 0
    fi

    predicted_file="$probe_dir/predicted_pkgfiles.txt"
    [ -f "$predicted_file" ] || die "probe did not produce predicted_pkgfiles.txt for $NAME"

    current_pkgfiles=$(tr '\n' ' ' <"$predicted_file" | sed 's/[[:space:]]*$//')
    if [ "$current_pkgfiles" != "$previous_pkgfiles" ]; then
        log "$NAME: predicted pkgfiles changed, queued"
        queue_package "$NAME"
        return 0
    fi

    log "$NAME: unchanged, skipped"
}

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

    tmp_dir=$(mktemp -d)
    if [ "$UPDATE_VCS" = "1" ]; then
        check_vcs_package "$manifest" "$tmp_dir"
        rm -rf "$tmp_dir"
        continue
    fi

    check_regular_package "$tmp_dir"
    rm -rf "$tmp_dir"
done
