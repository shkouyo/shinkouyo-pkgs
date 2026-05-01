#!/bin/sh

set -eu

VCS_EXPECTED_FINGERPRINT_KIND='git-heads-sha256-v1'

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

vcs_state_fingerprint_for_compare() {
    state_version=$1
    fingerprint=$2
    fingerprint_kind=$3

    case $state_version in
        1|2)
            normalize_vcs_fingerprint "$fingerprint"
            ;;
        3)
            printf '%s\n' "$fingerprint"
            ;;
        4)
            if [ -n "$fingerprint" ] && [ "$fingerprint_kind" != "$VCS_EXPECTED_FINGERPRINT_KIND" ]; then
                return 1
            fi
            printf '%s\n' "$fingerprint"
            ;;
        *)
            return 1
            ;;
    esac
}

vcs_current_fingerprint_for_compare() {
    state_version=$1
    current_fingerprint=$2
    current_details=$3

    case $state_version in
        1|2)
            normalize_vcs_fingerprint "$current_details"
            ;;
        3|4)
            printf '%s\n' "$current_fingerprint"
            ;;
        *)
            return 1
            ;;
    esac
}

vcs_decide_probe_result() {
    name=$1
    old_state_version=$2
    old_pkgfiles=$3
    old_vcs_fingerprint=$4
    old_vcs_fingerprint_kind=$5
    current_pkgfiles=$6
    current_vcs_fingerprint=$7
    current_vcs_details=$8

    VCS_DECISION=queue
    VCS_DECISION_LOG="$name: unknown VCS state, queued"

    if ! old_vcs_compare=$(vcs_state_fingerprint_for_compare "$old_state_version" "$old_vcs_fingerprint" "$old_vcs_fingerprint_kind"); then
        VCS_DECISION_LOG="$name: unsupported previous VCS fingerprint kind, queued"
        return 0
    fi
    if ! current_vcs_compare=$(vcs_current_fingerprint_for_compare "$old_state_version" "$current_vcs_fingerprint" "$current_vcs_details"); then
        VCS_DECISION_LOG="$name: unsupported current VCS fingerprint kind, queued"
        return 0
    fi

    if [ -z "$current_vcs_compare" ]; then
        if [ -z "$old_vcs_compare" ]; then
            if [ "$current_pkgfiles" != "$old_pkgfiles" ]; then
                VCS_DECISION=skip
                VCS_DECISION_LOG="$name: predicted pkgfiles changed without source or VCS changes, skipped"
                return 0
            fi
            VCS_DECISION=skip
            VCS_DECISION_LOG="$name: empty VCS fingerprint, skipped"
            return 0
        fi
        VCS_DECISION_LOG="$name: VCS fingerprint disappeared, queued"
        return 0
    fi

    if [ -z "$old_vcs_compare" ]; then
        VCS_DECISION=skip
        VCS_DECISION_LOG="$name: missing previous VCS fingerprint; keeping existing state package files, skipped"
        return 0
    fi

    if [ "$current_vcs_compare" != "$old_vcs_compare" ]; then
        VCS_DECISION_LOG="$name: VCS fingerprint changed, queued"
        return 0
    fi

    if [ "$current_pkgfiles" != "$old_pkgfiles" ]; then
        VCS_DECISION=skip
        VCS_DECISION_LOG="$name: predicted pkgfiles changed without source or VCS changes, skipped"
        return 0
    fi

    VCS_DECISION=skip
    VCS_DECISION_LOG="$name: unchanged, skipped"
}
