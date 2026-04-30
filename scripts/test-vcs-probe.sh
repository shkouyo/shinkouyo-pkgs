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
assert_contains_pkgfile "$old_pkgfiles" "$old_expected_pkgfile"

printf '%s\n' two >>"$upstream_repo/source.txt"
git_commit "$upstream_repo" two
new_expected_pkgfile=$(expected_pkgfile "$upstream_repo")

probe_dir="$tmp_dir/probe-new"
"$SCRIPT_DIR/build.sh" probe-vcs "$packages_dir/local-vcs-git.sh" "$probe_dir"
new_pkgfiles=$(cat "$probe_dir/predicted_pkgfiles.txt")
assert_contains_pkgfile "$new_pkgfiles" "$new_expected_pkgfile"
[ "$new_pkgfiles" != "$old_pkgfiles" ] || die "VCS probe did not change after upstream advanced"

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

write_fake_aws "$bin_dir"

queued=$(
    TEST_STATE_DIR=$state_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ "$queued" = 'local-vcs-git' ] || die "VCS package was not queued after upstream advanced: $queued"

printf '%s\n' 'vcs probe regression checks passed'
