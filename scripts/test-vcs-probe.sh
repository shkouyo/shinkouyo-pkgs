#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

require_cmd git
require_cmd mktemp

PACKAGER=${PACKAGER:-'Probe Test <probe@example.invalid>'}
GPG_PRIVATE_KEY=${GPG_PRIVATE_KEY:-dummy}
GPG_KEY_ID=${GPG_KEY_ID:-dummy}
REPO_NAME=${REPO_NAME:-probe-test}
S3_BUCKET=${S3_BUCKET:-probe-test}
S3_ENDPOINT=${S3_ENDPOINT:-https://example.invalid}
S3_REGION=${S3_REGION:-auto}
export PACKAGER GPG_PRIVATE_KEY GPG_KEY_ID REPO_NAME S3_BUCKET S3_ENDPOINT S3_REGION

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

assert_probe_success() {
    manifest_name=$1
    expected_pkgfile=$2

    probe_dir="$tmp_dir/$manifest_name"
    "$SCRIPT_DIR/build.sh" probe-vcs "$ROOT_DIR/packages/$manifest_name.sh" "$probe_dir"

    predicted_pkgfiles_file="$probe_dir/predicted_pkgfiles.txt"
    [ -s "$predicted_pkgfiles_file" ] || die "probe output missing for $manifest_name"

    predicted_pkgfiles=$(cat "$predicted_pkgfiles_file")
    case " $predicted_pkgfiles " in
        *" $expected_pkgfile "*) ;;
        *)
            die "expected $expected_pkgfile in predicted pkgfiles for $manifest_name, got: $predicted_pkgfiles"
            ;;
    esac
}

assert_probe_success niri-git niri-git-25.11.r108.g549148d-2-x86_64.pkg.tar.zst
assert_probe_success pins-git pins-git-2.4.5.r3.ge59d0c5-1-x86_64.pkg.tar.zst
assert_probe_success shorin-contrib-git shorin-contrib-git-r35.338da1c-2-any.pkg.tar.zst

printf '%s\n' 'vcs probe regression checks passed'
