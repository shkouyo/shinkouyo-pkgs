#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"

require_cmd git
require_cmd mktemp

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

git_commit() {
    repo=$1
    message=$2

    (
        cd "$repo"
        git add .
        git -c commit.gpgsign=false commit -q -m "$message"
    )
}

write_fake_aws() {
    bin_dir=$1

    mkdir -p "$bin_dir"
    cat >"$bin_dir/aws" <<'EOF'
#!/bin/sh

set -eu

[ "$#" -ge 6 ] || exit 2
[ "$1" = "s3" ] || exit 2
[ "$2" = "cp" ] || exit 2
shift 2

if [ "${1-}" = "--endpoint-url" ]; then
    shift 2
fi

src=$1
dest=$2

case $src in
    s3://*/.state/x86_64/*.env)
        file=${src##*/}
        cp "$TEST_STATE_DIR/$file" "$dest"
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod +x "$bin_dir/aws"
}

source_repo="$tmp_dir/regular-source"
packages_dir="$tmp_dir/packages"
state_dir="$tmp_dir/state"
bin_dir="$tmp_dir/bin"
mkdir -p "$source_repo" "$packages_dir" "$state_dir"

(
    cd "$source_repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name test
    git config commit.gpgsign false
    printf '%s\n' one > regular.txt
)
git_commit "$source_repo" one
source_ref=$(cd "$source_repo" && git rev-parse --abbrev-ref HEAD)
old_commit=$(cd "$source_repo" && git rev-parse HEAD)

cat >"$packages_dir/demo-regular.sh" <<EOF
# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='demo-regular'

SOURCE_GIT='$source_repo'
SOURCE_REF='$source_ref'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
EOF

cat >"$state_dir/demo-regular.env" <<EOF
STATE_VERSION=2
NAME='demo-regular'
SOURCE_GIT='$source_repo'
SOURCE_REF='$source_ref'
LAST_SOURCE_COMMIT='$old_commit'
PKGNAMES='demo-regular'
PKGFILES='demo-regular-1-1-any.pkg.tar.zst'
VCS_FINGERPRINT=''
BUILT_AT='2026-01-01T00:00:00Z'
EOF

write_fake_aws "$bin_dir"

common_env() {
    REPO_NAME=repo-test \
    S3_BUCKET=bucket-test \
    S3_ENDPOINT=https://example.invalid \
    S3_REGION=auto \
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    "$@"
}

unchanged=$(common_env sh "$ROOT_DIR/scripts/check-updates.sh" regular)
[ -z "$unchanged" ] || die "regular package was queued without a source ref change: $unchanged"

printf '%s\n' two >>"$source_repo/regular.txt"
git_commit "$source_repo" two

changed=$(common_env sh "$ROOT_DIR/scripts/check-updates.sh" regular)
[ "$changed" = 'demo-regular' ] || die "regular package was not queued after source ref changed: $changed"

github_output="$tmp_dir/github-output"
queue_stderr="$tmp_dir/queue.stderr"
common_env env GITHUB_OUTPUT="$github_output" sh "$ROOT_DIR/scripts/ci/queue-check-updates.sh" regular 2>"$queue_stderr"
grep -F -x 'packages=["demo-regular"]' "$github_output" >/dev/null
grep -F -x "check-updates[regular]: scanning $packages_dir" "$queue_stderr" >/dev/null
grep -F -x 'demo-regular: checking demo-regular.sh' "$queue_stderr" >/dev/null
grep -F -x 'check-updates[regular]: checked=1 queued=1 skipped=0' "$queue_stderr" >/dev/null
grep -F -x 'queue-check-updates[regular]: queued=1' "$queue_stderr" >/dev/null
grep -F -x 'queue-check-updates[regular]: queued package: demo-regular' "$queue_stderr" >/dev/null

missing_output="$tmp_dir/missing-output"
missing_stderr="$tmp_dir/missing.stderr"
if common_env env GITHUB_OUTPUT="$missing_output" PACKAGES_DIR="$tmp_dir/missing" sh "$ROOT_DIR/scripts/ci/queue-check-updates.sh" regular >/dev/null 2>"$missing_stderr"; then
    die "queue-check-updates.sh succeeded without a check summary"
fi
grep -F -x 'error: check-updates[regular] did not print a summary' "$missing_stderr" >/dev/null

vcs_empty_output="$tmp_dir/vcs-empty-output"
vcs_empty_stderr="$tmp_dir/vcs-empty.stderr"
if common_env env GITHUB_OUTPUT="$vcs_empty_output" sh "$ROOT_DIR/scripts/ci/queue-check-updates.sh" vcs >/dev/null 2>"$vcs_empty_stderr"; then
    die "VCS queue check succeeded without checking any VCS packages"
fi
grep -F -x 'check-updates[vcs]: checked=0 queued=0 skipped=0' "$vcs_empty_stderr" >/dev/null
grep -F -x 'error: VCS update scan did not check any packages' "$vcs_empty_stderr" >/dev/null

printf '%s\n' 'check-updates checks passed'
