#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
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

require_update_env
require_cmd git
require_cmd aws

packages_dir=${PACKAGES_DIR:-"$ROOT_DIR/packages"}
if [ ! -d "$packages_dir" ]; then
    log "check-updates[$mode]: packages directory not found: $packages_dir"
    exit 0
fi

checked_count=0
queued_count=0
skipped_count=0

queue_package() {
    package=$1

    require_package_name "$package"
    queued_count=$((queued_count + 1))
    printf '%s\n' "$package"
}

skip_package() {
    skipped_count=$((skipped_count + 1))
}

log_file_tail() {
    label=$1
    file=$2

    [ -f "$file" ] || return 0
    [ -s "$file" ] || return 0

    log "$label:"
    tail -n 50 "$file" >&2
}

normalize_vcs_fingerprint() {
    fingerprint=$1

    printf '%s\n' "$fingerprint" | awk '
        {
            i = 1
            while (i <= NF) {
                rel = $i
                kind = $(i + 1)
                if (kind == "HEAD" && i + 2 <= NF) {
                    print rel " HEAD " $(i + 2)
                    i += 3
                } else if (kind == "ref" && i + 3 <= NF) {
                    i += 4
                } else {
                    i++
                }
            }
        }
    ' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
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

    eval "$(state_emit_prefixed OLD "$state_file")"
    if ! repo_pkgfiles_exist "$OLD_PKGFILES"; then
        log "$NAME: state package files missing, queued"
        queue_package "$NAME"
        return 0
    fi

    remote_line=$(git ls-remote "$manifest_source_git" "$manifest_source_ref" | awk 'NR==1{print $1}')
    [ -n "$remote_line" ] || die "failed to resolve remote ref for $NAME"
    if [ "$remote_line" != "$OLD_LAST_SOURCE_COMMIT" ]; then
        log "$NAME: source commit changed, queued"
        queue_package "$NAME"
        return 0
    fi

    log "$NAME: source commit unchanged, skipped"
    skip_package
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

    eval "$(state_emit_prefixed OLD "$state_file")"

    remote_line=$(git ls-remote "$SOURCE_GIT" "$SOURCE_REF" | awk 'NR==1{print $1}')
    [ -n "$remote_line" ] || die "failed to resolve remote ref for $NAME"

    if ! repo_pkgfiles_exist "$OLD_PKGFILES"; then
        log "$NAME: state package files missing, queued"
        queue_package "$NAME"
        return 0
    fi

    log "$NAME: probing VCS package metadata"
    probe_dir="$tmp_dir/probe"
    mkdir -p "$probe_dir"
    probe_stdout="$tmp_dir/probe.stdout"
    probe_stderr="$tmp_dir/probe.stderr"
    if ! "$SCRIPT_DIR/build.sh" probe-vcs "$manifest_path" "$probe_dir" >"$probe_stdout" 2>"$probe_stderr"; then
        probe_error=$(awk 'NF { line=$0 } END { print line }' "$probe_stderr")
        if [ -n "$probe_error" ]; then
            log "$NAME: probe error: $probe_error"
        fi
        log_file_tail "$NAME: probe stderr tail" "$probe_stderr"
        log_file_tail "$NAME: probe stdout tail" "$probe_stdout"
        log_file_tail "$NAME: predicted stderr tail" "$probe_dir/predicted_pkgfiles.stderr"
        log_file_tail "$NAME: predicted stdout tail" "$probe_dir/predicted_pkgfiles.stdout"
        die "$NAME: probe failed"
    fi

    predicted_pkgfiles_file="$probe_dir/predicted_pkgfiles.txt"
    [ -f "$predicted_pkgfiles_file" ] || die "probe did not produce predicted_pkgfiles.txt for $NAME"
    recipe_fingerprint_file="$probe_dir/recipe_fingerprint.txt"
    [ -f "$recipe_fingerprint_file" ] || die "probe did not produce recipe_fingerprint.txt for $NAME"
    vcs_fingerprint_file="$probe_dir/vcs_fingerprint.txt"
    [ -f "$vcs_fingerprint_file" ] || die "probe did not produce vcs_fingerprint.txt for $NAME"
    vcs_fingerprint_details_file="$probe_dir/vcs_fingerprint.details"
    [ -f "$vcs_fingerprint_details_file" ] || die "probe did not produce vcs_fingerprint.details for $NAME"

    current_predicted_pkgfiles=$(awk 'NF { print; exit }' "$predicted_pkgfiles_file")
    [ -n "$current_predicted_pkgfiles" ] || die "probe did not predict any package files for $NAME"
    predicted_pkgfiles_changed=0
    if [ "$current_predicted_pkgfiles" != "$OLD_PKGFILES" ]; then
        predicted_pkgfiles_changed=1
    fi

    current_recipe_fingerprint=$(awk 'NF { print; exit }' "$recipe_fingerprint_file")
    [ -n "$current_recipe_fingerprint" ] || die "probe did not produce a recipe fingerprint for $NAME"
    if [ -n "${OLD_RECIPE_FINGERPRINT-}" ]; then
        if [ "$current_recipe_fingerprint" != "$OLD_RECIPE_FINGERPRINT" ]; then
            log "$NAME: recipe fingerprint changed, queued"
            queue_package "$NAME"
            return 0
        fi
    elif [ "$remote_line" != "$OLD_LAST_SOURCE_COMMIT" ]; then
        log "$NAME: source commit changed and previous recipe fingerprint is missing, queued"
        queue_package "$NAME"
        return 0
    fi

    current_vcs_fingerprint=$(awk 'NF { print; exit }' "$vcs_fingerprint_file")
    if [ "${OLD_STATE_VERSION-}" = "3" ]; then
        old_vcs_fingerprint=$OLD_VCS_FINGERPRINT
    else
        old_vcs_fingerprint=$(normalize_vcs_fingerprint "$OLD_VCS_FINGERPRINT")
        current_vcs_fingerprint=$(normalize_vcs_fingerprint "$(cat "$vcs_fingerprint_details_file")")
    fi

    if [ -z "$current_vcs_fingerprint" ]; then
        if [ -z "$old_vcs_fingerprint" ]; then
            if [ "$predicted_pkgfiles_changed" -eq 1 ]; then
                if repo_pkgfiles_exist "$current_predicted_pkgfiles"; then
                    log "$NAME: predicted pkgfiles changed but existing package files are already present, skipped"
                else
                    log "$NAME: predicted pkgfiles changed and package files are missing, queued"
                    queue_package "$NAME"
                    return 0
                fi
            else
                log "$NAME: empty VCS fingerprint, skipped"
            fi
            skip_package
            return 0
        fi
        log "$NAME: VCS fingerprint disappeared, queued"
        queue_package "$NAME"
        return 0
    fi

    if [ -z "$old_vcs_fingerprint" ]; then
        if [ "$predicted_pkgfiles_changed" -eq 1 ]; then
            if repo_pkgfiles_exist "$current_predicted_pkgfiles"; then
                log "$NAME: missing previous VCS fingerprint but predicted pkgfiles already exist, skipped"
                skip_package
            else
                log "$NAME: missing previous VCS fingerprint and predicted pkgfiles changed, queued"
                queue_package "$NAME"
            fi
        else
            log "$NAME: missing previous VCS fingerprint but predicted pkgfiles unchanged, skipped"
            skip_package
        fi
        return 0
    fi

    if [ "$current_vcs_fingerprint" != "$old_vcs_fingerprint" ]; then
        log "$NAME: VCS fingerprint changed, queued"
        queue_package "$NAME"
        return 0
    fi

    if [ "$predicted_pkgfiles_changed" -eq 1 ]; then
        if repo_pkgfiles_exist "$current_predicted_pkgfiles"; then
            log "$NAME: predicted pkgfiles changed but existing package files are already present, skipped"
        else
            log "$NAME: predicted pkgfiles changed and package files are missing, queued"
            queue_package "$NAME"
            return 0
        fi
        skip_package
        return 0
    fi

    log "$NAME: unchanged, skipped"
    skip_package
}

log "check-updates[$mode]: scanning $packages_dir"

for manifest in "$packages_dir"/*.sh; do
    [ -e "$manifest" ] || continue

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

    checked_count=$((checked_count + 1))
    log "$NAME: checking $(basename "$manifest")"

    tmp_dir=$(mktemp -d)
    if [ "$UPDATE_VCS" = "1" ]; then
        check_vcs_package "$manifest" "$tmp_dir"
        rm -rf "$tmp_dir"
        continue
    fi

    check_regular_package "$tmp_dir"
    rm -rf "$tmp_dir"
done

log "check-updates[$mode]: checked=$checked_count queued=$queued_count skipped=$skipped_count"
