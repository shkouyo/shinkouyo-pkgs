#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"

require_cmd git
require_cmd makepkg
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

git_commit() {
    repo=$1
    message=$2

    (
        cd "$repo"
        git add .
        git -c commit.gpgsign=false commit -q -m "$message"
    )
}

expected_pkgfile() {
    repo=$1

    (
        cd "$repo"
        printf 'local-vcs-git-r%s.g%s-1-any.pkg.tar.zst\n' \
            "$(git rev-list --count HEAD)" \
            "$(git rev-parse --short HEAD)"
    )
}

assert_contains_pkgfile() {
    pkgfiles=$1
    expected=$2

    case " $pkgfiles " in
        *" $expected "*) ;;
        *) die "expected $expected in predicted pkgfiles, got: $pkgfiles" ;;
    esac
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

upstream_repo="$tmp_dir/upstream"
pkgbuild_repo="$tmp_dir/pkgbuild-repo"
packages_dir="$tmp_dir/packages"
state_dir="$tmp_dir/state"
bin_dir="$tmp_dir/bin"
mkdir -p "$upstream_repo" "$pkgbuild_repo" "$packages_dir" "$state_dir"

(
    cd "$upstream_repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name test
    git config commit.gpgsign false
    printf '%s\n' one > source.txt
)
git_commit "$upstream_repo" one
old_expected_pkgfile=$(expected_pkgfile "$upstream_repo")

cat >"$pkgbuild_repo/PKGBUILD" <<EOF
pkgname=local-vcs-git
pkgver=r1.g0000000
pkgrel=1
pkgdesc='local VCS probe fixture'
arch=('any')
license=('MIT')
source=("local-vcs-git::git+file://$upstream_repo")
sha256sums=('SKIP')

pkgver() {
    cd "\$srcdir/local-vcs-git"
    printf 'r%s.g%s' "\$(git rev-list --count HEAD)" "\$(git rev-parse --short HEAD)"
}

package() {
    mkdir -p "\$pkgdir/usr/share/local-vcs-git"
    printf '%s\n' fixture > "\$pkgdir/usr/share/local-vcs-git/source.txt"
}
EOF

(
    cd "$pkgbuild_repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name test
    git config commit.gpgsign false
)
git_commit "$pkgbuild_repo" pkgbuild
pkgbuild_ref=$(cd "$pkgbuild_repo" && git rev-parse --abbrev-ref HEAD)
pkgbuild_commit=$(cd "$pkgbuild_repo" && git rev-parse HEAD)

cat >"$packages_dir/local-vcs-git.sh" <<EOF
# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='local-vcs-git'

SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
EOF

probe_dir="$tmp_dir/probe-old"
"$SCRIPT_DIR/build.sh" probe-vcs "$packages_dir/local-vcs-git.sh" "$probe_dir"
old_pkgfiles=$(cat "$probe_dir/predicted_pkgfiles.txt")
old_fingerprint=$(cat "$probe_dir/vcs_fingerprint.txt")
assert_contains_pkgfile "$old_pkgfiles" "$old_expected_pkgfile"
[ -n "$old_fingerprint" ] || die "old VCS fingerprint was empty"

printf '%s\n' two >>"$upstream_repo/source.txt"
git_commit "$upstream_repo" two
new_expected_pkgfile=$(expected_pkgfile "$upstream_repo")

probe_dir="$tmp_dir/probe-new"
"$SCRIPT_DIR/build.sh" probe-vcs "$packages_dir/local-vcs-git.sh" "$probe_dir"
new_pkgfiles=$(cat "$probe_dir/predicted_pkgfiles.txt")
new_fingerprint=$(cat "$probe_dir/vcs_fingerprint.txt")
assert_contains_pkgfile "$new_pkgfiles" "$new_expected_pkgfile"
[ "$new_pkgfiles" != "$old_pkgfiles" ] || die "VCS probe did not change after upstream advanced"
[ -n "$new_fingerprint" ] || die "new VCS fingerprint was empty"
[ "$new_fingerprint" != "$old_fingerprint" ] || die "VCS fingerprint did not change after upstream advanced"

write_fake_aws "$bin_dir"

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
VCS_FINGERPRINT=''
BUILT_AT='2026-01-01T00:00:00Z'
EOF

missing_fingerprint_unchanged_stderr="$tmp_dir/missing-fingerprint-unchanged.stderr"
missing_fingerprint_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$missing_fingerprint_unchanged_stderr"
)
[ -z "$missing_fingerprint_unchanged" ] || die "VCS package was queued with missing fingerprint but unchanged pkgfiles: $missing_fingerprint_unchanged"
grep -F -x 'local-vcs-git: missing previous VCS fingerprint but predicted pkgfiles unchanged, skipped' "$missing_fingerprint_unchanged_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$old_pkgfiles'
VCS_FINGERPRINT=''
BUILT_AT='2026-01-01T00:00:00Z'
EOF

missing_fingerprint_changed_stderr="$tmp_dir/missing-fingerprint-changed.stderr"
missing_fingerprint_changed=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$missing_fingerprint_changed_stderr"
)
[ "$missing_fingerprint_changed" = 'local-vcs-git' ] || die "VCS package was not queued with missing fingerprint and changed pkgfiles: $missing_fingerprint_changed"
grep -F -x 'local-vcs-git: missing previous VCS fingerprint and predicted pkgfiles changed, queued' "$missing_fingerprint_changed_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$old_pkgfiles'
VCS_FINGERPRINT='$new_fingerprint'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

pkgfiles_only_stderr="$tmp_dir/pkgfiles-only.stderr"
pkgfiles_only_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$pkgfiles_only_stderr"
)
[ -z "$pkgfiles_only_unchanged" ] || die "VCS package was queued for predicted pkgfile drift only: $pkgfiles_only_unchanged"
grep -F -x 'local-vcs-git: predicted pkgfiles changed but VCS fingerprint unchanged, skipped' "$pkgfiles_only_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
VCS_FINGERPRINT='$old_fingerprint'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

queued=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ "$queued" = 'local-vcs-git' ] || die "VCS package was not queued after fingerprint changed: $queued"

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
VCS_FINGERPRINT='$new_fingerprint'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$unchanged" ] || die "VCS package was queued without source, fingerprint, or pkgfile changes: $unchanged"

noisy_fingerprint="$new_fingerprint local-vcs-git ref refs/remotes/origin/main 0000000000000000000000000000000000000000 local-vcs-git ref refs/tags/noise 1111111111111111111111111111111111111111"
cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
VCS_FINGERPRINT='$noisy_fingerprint'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

legacy_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$legacy_unchanged" ] || die "VCS package was queued for legacy noisy refs: $legacy_unchanged"

(
    cd "$upstream_repo"
    git branch probe-noise HEAD
    git -c tag.gpgsign=false tag --no-sign probe-noise-tag HEAD
)

ref_noise_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$ref_noise_unchanged" ] || die "VCS package was queued for upstream ref-only changes: $ref_noise_unchanged"

plain_pkgbuild_repo="$tmp_dir/plain-pkgbuild-repo"
mkdir -p "$plain_pkgbuild_repo"
cat >"$plain_pkgbuild_repo/PKGBUILD" <<'EOF'
pkgname=plain-vcs-git
pkgver=1
pkgrel=1
pkgdesc='plain VCS probe fixture without VCS sources'
arch=('any')
license=('MIT')

package() {
    mkdir -p "$pkgdir/usr/share/plain-vcs-git"
    printf '%s\n' fixture > "$pkgdir/usr/share/plain-vcs-git/source.txt"
}
EOF

(
    cd "$plain_pkgbuild_repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name test
    git config commit.gpgsign false
)
git_commit "$plain_pkgbuild_repo" plain
plain_ref=$(cd "$plain_pkgbuild_repo" && git rev-parse --abbrev-ref HEAD)
plain_commit=$(cd "$plain_pkgbuild_repo" && git rev-parse HEAD)

cat >"$packages_dir/plain-vcs-git.sh" <<EOF
# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='plain-vcs-git'

SOURCE_GIT='$plain_pkgbuild_repo'
SOURCE_REF='$plain_ref'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
EOF

plain_probe_dir="$tmp_dir/plain-probe"
"$SCRIPT_DIR/build.sh" probe-vcs "$packages_dir/plain-vcs-git.sh" "$plain_probe_dir"
plain_pkgfiles=$(cat "$plain_probe_dir/predicted_pkgfiles.txt")
plain_fingerprint=$(cat "$plain_probe_dir/vcs_fingerprint.txt")
case " $plain_pkgfiles " in
    *" plain-vcs-git-1-1-any.pkg.tar.zst "*) ;;
    *) die "plain VCS probe predicted unexpected pkgfiles: $plain_pkgfiles" ;;
esac
[ -z "$plain_fingerprint" ] || die "plain VCS probe unexpectedly produced fingerprint: $plain_fingerprint"

cat >"$state_dir/plain-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='plain-vcs-git'
SOURCE_GIT='$plain_pkgbuild_repo'
SOURCE_REF='$plain_ref'
LAST_SOURCE_COMMIT='$plain_commit'
PKGNAMES='plain-vcs-git'
PKGFILES='$plain_pkgfiles'
VCS_FINGERPRINT=''
BUILT_AT='2026-01-01T00:00:00Z'
EOF

plain_empty_stderr="$tmp_dir/plain-empty.stderr"
empty_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$plain_empty_stderr"
)
[ -z "$empty_unchanged" ] || die "VCS package with empty fingerprint and unchanged pkgfiles was queued: $empty_unchanged"
grep -F -x 'plain-vcs-git: empty VCS fingerprint, skipped' "$plain_empty_stderr" >/dev/null

cat >"$state_dir/plain-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='plain-vcs-git'
SOURCE_GIT='$plain_pkgbuild_repo'
SOURCE_REF='$plain_ref'
LAST_SOURCE_COMMIT='$plain_commit'
PKGNAMES='plain-vcs-git'
PKGFILES='plain-vcs-git-0-1-any.pkg.tar.zst'
VCS_FINGERPRINT=''
BUILT_AT='2026-01-01T00:00:00Z'
EOF

empty_pkgfiles_drift_stderr="$tmp_dir/empty-pkgfiles-drift.stderr"
empty_pkgfiles_drift_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$empty_pkgfiles_drift_stderr"
)
[ -z "$empty_pkgfiles_drift_unchanged" ] || die "VCS package with empty fingerprint and pkgfile drift was queued: $empty_pkgfiles_drift_unchanged"
grep -F -x 'plain-vcs-git: predicted pkgfiles changed but VCS fingerprint is empty, skipped' "$empty_pkgfiles_drift_stderr" >/dev/null

printf '%s\n' 'vcs probe regression checks passed'
