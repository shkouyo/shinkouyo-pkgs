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

case "${1-}:${2-}" in
    s3:cp)
        [ "$#" -ge 6 ] || exit 2
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
        ;;
    s3api:head-object)
        shift 2
        key=''
        while [ "$#" -gt 0 ]; do
            case $1 in
                --endpoint-url|--bucket)
                    shift 2
                    ;;
                --key)
                    key=$2
                    shift 2
                    ;;
                *)
                    exit 2
                    ;;
            esac
        done
        [ -n "$key" ] || exit 2
        [ -f "${TEST_OBJECT_DIR:-/nonexistent}/$key" ] || exit 1
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
object_dir="$tmp_dir/objects"
bin_dir="$tmp_dir/bin"
mkdir -p "$upstream_repo" "$pkgbuild_repo" "$packages_dir" "$state_dir" "$object_dir"

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

prepare() {
    rm -rf "\$srcdir/local-vcs-git/build-cache"
    mkdir -p "\$srcdir/local-vcs-git/build-cache/noise"
    cd "\$srcdir/local-vcs-git/build-cache/noise"
    git init -q
    git config user.email test@example.invalid
    git config user.name test
    git config commit.gpgsign false
    printf '%s\n' ignored > generated.txt
    git add generated.txt
    git -c commit.gpgsign=false commit -q -m ignored
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
old_fingerprint_details=$(tr '\n' ' ' <"$probe_dir/vcs_fingerprint.details" | sed 's/[[:space:]]*$//')
assert_contains_pkgfile "$old_pkgfiles" "$old_expected_pkgfile"
[ -n "$old_fingerprint" ] || die "old VCS fingerprint was empty"
[ -n "$old_fingerprint_details" ] || die "old VCS fingerprint details were empty"

printf '%s\n' two >>"$upstream_repo/source.txt"
git_commit "$upstream_repo" two
new_expected_pkgfile=$(expected_pkgfile "$upstream_repo")

probe_dir="$tmp_dir/probe-new"
"$SCRIPT_DIR/build.sh" probe-vcs "$packages_dir/local-vcs-git.sh" "$probe_dir"
new_pkgfiles=$(cat "$probe_dir/predicted_pkgfiles.txt")
new_fingerprint=$(cat "$probe_dir/vcs_fingerprint.txt")
new_fingerprint_details=$(tr '\n' ' ' <"$probe_dir/vcs_fingerprint.details" | sed 's/[[:space:]]*$//')
new_recipe_fingerprint=$(cat "$probe_dir/recipe_fingerprint.txt")
assert_contains_pkgfile "$new_pkgfiles" "$new_expected_pkgfile"
[ "$new_pkgfiles" != "$old_pkgfiles" ] || die "VCS probe did not change after upstream advanced"
[ -n "$new_fingerprint" ] || die "new VCS fingerprint was empty"
[ "$new_fingerprint" != "$old_fingerprint" ] || die "VCS fingerprint did not change after upstream advanced"
[ -n "$new_fingerprint_details" ] || die "new VCS fingerprint details were empty"
case $new_fingerprint_details in
    *build-cache*) die "VCS fingerprint included a nested build-generated Git repo: $new_fingerprint_details" ;;
esac
[ -n "$new_recipe_fingerprint" ] || die "new recipe fingerprint was empty"
[ -d "$probe_dir/makepkg-builddir/local-vcs-git/src/local-vcs-git/.git" ] || die "probe did not use context makepkg BUILDDIR"
grep -F -x "PROBE_VERSION='vcs-probe-v9'" "$probe_dir/probe.env" >/dev/null ||
    die "probe.env did not include probe version"
grep -F -x "VCS_FINGERPRINT_KIND='git-source-heads-sha256-v1'" "$probe_dir/probe.env" >/dev/null ||
    die "probe.env did not include VCS fingerprint kind"

write_fake_aws "$bin_dir"

mkdir -p "$object_dir/$PKG_PREFIX"
for old_pkgfile in $old_pkgfiles; do
    : >"$object_dir/$PKG_PREFIX/$old_pkgfile"
    : >"$object_dir/$PKG_PREFIX/$old_pkgfile.sig"
done
for new_pkgfile in $new_pkgfiles; do
    : >"$object_dir/$PKG_PREFIX/$new_pkgfile"
    : >"$object_dir/$PKG_PREFIX/$new_pkgfile.sig"
done

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
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$missing_fingerprint_unchanged_stderr"
)
[ -z "$missing_fingerprint_unchanged" ] || die "VCS package was queued with missing fingerprint but unchanged pkgfiles: $missing_fingerprint_unchanged"
grep -F -x 'local-vcs-git: missing previous VCS fingerprint; keeping existing state package files, skipped' "$missing_fingerprint_unchanged_stderr" >/dev/null

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

for new_pkgfile in $new_pkgfiles; do
    rm -f "$object_dir/$PKG_PREFIX/$new_pkgfile" "$object_dir/$PKG_PREFIX/$new_pkgfile.sig"
done

missing_fingerprint_changed_stderr="$tmp_dir/missing-fingerprint-changed.stderr"
missing_fingerprint_changed=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$missing_fingerprint_changed_stderr"
)
[ -z "$missing_fingerprint_changed" ] || die "VCS package was queued with missing fingerprint and changed pkgfiles: $missing_fingerprint_changed"
grep -F -x 'local-vcs-git: missing previous VCS fingerprint; keeping existing state package files, skipped' "$missing_fingerprint_changed_stderr" >/dev/null

for new_pkgfile in $new_pkgfiles; do
    : >"$object_dir/$PKG_PREFIX/$new_pkgfile"
    : >"$object_dir/$PKG_PREFIX/$new_pkgfile.sig"
done

missing_fingerprint_existing_stderr="$tmp_dir/missing-fingerprint-existing.stderr"
missing_fingerprint_existing=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$missing_fingerprint_existing_stderr"
)
[ -z "$missing_fingerprint_existing" ] || die "VCS package was queued with missing fingerprint and existing predicted pkgfiles: $missing_fingerprint_existing"
grep -F -x 'local-vcs-git: missing previous VCS fingerprint; keeping existing state package files, skipped' "$missing_fingerprint_existing_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$old_pkgfiles'
VCS_FINGERPRINT='$new_fingerprint_details'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

pkgfiles_only_stderr="$tmp_dir/pkgfiles-only.stderr"
pkgfiles_only_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$pkgfiles_only_stderr"
)
[ -z "$pkgfiles_only_unchanged" ] || die "VCS package was queued for predicted pkgfile drift with existing files: $pkgfiles_only_unchanged"
grep -F -x 'local-vcs-git: predicted pkgfiles changed without source or VCS changes, skipped' "$pkgfiles_only_stderr" >/dev/null

for new_pkgfile in $new_pkgfiles; do
    rm -f "$object_dir/$PKG_PREFIX/$new_pkgfile" "$object_dir/$PKG_PREFIX/$new_pkgfile.sig"
done

pkgfiles_only_missing_stderr="$tmp_dir/pkgfiles-only-missing.stderr"
pkgfiles_only_missing=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$pkgfiles_only_missing_stderr"
)
[ -z "$pkgfiles_only_missing" ] || die "VCS package was queued for predicted pkgfile drift with missing files: $pkgfiles_only_missing"
grep -F -x 'local-vcs-git: predicted pkgfiles changed without source or VCS changes, skipped' "$pkgfiles_only_missing_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$old_pkgfiles'
VCS_FINGERPRINT='$old_fingerprint_details'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

fingerprint_changed_missing_stderr="$tmp_dir/fingerprint-changed-missing.stderr"
fingerprint_changed_missing=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$fingerprint_changed_missing_stderr"
)
[ "$fingerprint_changed_missing" = 'local-vcs-git' ] || die "VCS package was not queued after fingerprint changed with missing predicted pkgfiles: $fingerprint_changed_missing"
grep -F -x 'local-vcs-git: VCS fingerprint changed, queued' "$fingerprint_changed_missing_stderr" >/dev/null

for new_pkgfile in $new_pkgfiles; do
    : >"$object_dir/$PKG_PREFIX/$new_pkgfile"
    : >"$object_dir/$PKG_PREFIX/$new_pkgfile.sig"
done

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=2
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
VCS_FINGERPRINT='$old_fingerprint_details'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

queued=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
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
VCS_FINGERPRINT='$new_fingerprint_details'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

unchanged=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$unchanged" ] || die "VCS package was queued without source, fingerprint, or pkgfile changes: $unchanged"

noisy_fingerprint="$new_fingerprint_details local-vcs-git ref refs/remotes/origin/main 0000000000000000000000000000000000000000 local-vcs-git ref refs/tags/noise 1111111111111111111111111111111111111111"
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
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$legacy_unchanged" ] || die "VCS package was queued for legacy noisy refs: $legacy_unchanged"

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=4
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
RECIPE_FINGERPRINT='$new_recipe_fingerprint'
VCS_FINGERPRINT='$new_fingerprint'
PROBE_VERSION='vcs-probe-v9'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-source-heads-sha256-v1'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

v4_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$v4_unchanged" ] || die "VCS package was queued for unchanged v4 state: $v4_unchanged"

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=4
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
RECIPE_FINGERPRINT='$new_recipe_fingerprint'
VCS_FINGERPRINT='$old_fingerprint'
PROBE_VERSION='vcs-probe-v9'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-source-heads-sha256-v1'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

v4_changed_stderr="$tmp_dir/v4-changed.stderr"
v4_changed=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$v4_changed_stderr"
)
[ "$v4_changed" = 'local-vcs-git' ] || die "VCS package was not queued for changed v4 state: $v4_changed"
grep -F -x 'local-vcs-git: VCS fingerprint changed, queued' "$v4_changed_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=4
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
RECIPE_FINGERPRINT='$new_recipe_fingerprint'
VCS_FINGERPRINT='legacy-v8-noisy-fingerprint'
PROBE_VERSION='vcs-probe-v8'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-heads-sha256-v1'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

legacy_v4_stderr="$tmp_dir/legacy-v4.stderr"
legacy_v4_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$legacy_v4_stderr"
)
[ -z "$legacy_v4_unchanged" ] || die "VCS package was queued for legacy v4 fingerprint kind migration: $legacy_v4_unchanged"
grep -F -x 'local-vcs-git: legacy VCS fingerprint kind changed, skipped' "$legacy_v4_stderr" >/dev/null

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=4
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
RECIPE_FINGERPRINT='$new_recipe_fingerprint'
VCS_FINGERPRINT='$new_fingerprint'
PROBE_VERSION='vcs-probe-v9'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-source-heads-sha256-v1'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

(
    cd "$upstream_repo"
    git branch probe-noise HEAD
    git -c tag.gpgsign=false tag --no-sign probe-noise-tag HEAD
)

ref_noise_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ -z "$ref_noise_unchanged" ] || die "VCS package was queued for upstream ref-only changes: $ref_noise_unchanged"

cat >"$state_dir/local-vcs-git.env" <<EOF
STATE_VERSION=3
NAME='local-vcs-git'
SOURCE_GIT='$pkgbuild_repo'
SOURCE_REF='$pkgbuild_ref'
LAST_SOURCE_COMMIT='$pkgbuild_commit'
PKGNAMES='local-vcs-git'
PKGFILES='$new_pkgfiles'
RECIPE_FINGERPRINT='$new_recipe_fingerprint'
VCS_FINGERPRINT='$new_fingerprint'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

printf '%s\n' 'generated = 1' >"$pkgbuild_repo/.SRCINFO"
git_commit "$pkgbuild_repo" srcinfo

srcinfo_noise_unchanged=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ "$srcinfo_noise_unchanged" = 'local-vcs-git' ] || die "VCS package was not queued for .SRCINFO-only source changes: $srcinfo_noise_unchanged"

printf '%s\n' '# recipe input changed' >>"$pkgbuild_repo/PKGBUILD"
git_commit "$pkgbuild_repo" recipe

recipe_changed=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs
)
[ "$recipe_changed" = 'local-vcs-git' ] || die "VCS package was not queued after recipe changed: $recipe_changed"

rm -f "$packages_dir/local-vcs-git.sh"

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

for plain_pkgfile in $plain_pkgfiles plain-vcs-git-0-1-any.pkg.tar.zst; do
    : >"$object_dir/$PKG_PREFIX/$plain_pkgfile"
    : >"$object_dir/$PKG_PREFIX/$plain_pkgfile.sig"
done

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
    TEST_OBJECT_DIR=$object_dir \
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
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$empty_pkgfiles_drift_stderr"
)
[ -z "$empty_pkgfiles_drift_unchanged" ] || die "VCS package with empty fingerprint and existing pkgfile drift was queued: $empty_pkgfiles_drift_unchanged"
grep -F -x 'plain-vcs-git: predicted pkgfiles changed without source or VCS changes, skipped' "$empty_pkgfiles_drift_stderr" >/dev/null

for plain_pkgfile in $plain_pkgfiles; do
    rm -f "$object_dir/$PKG_PREFIX/$plain_pkgfile" "$object_dir/$PKG_PREFIX/$plain_pkgfile.sig"
done

empty_pkgfiles_missing_stderr="$tmp_dir/empty-pkgfiles-missing.stderr"
empty_pkgfiles_missing=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$empty_pkgfiles_missing_stderr"
)
[ -z "$empty_pkgfiles_missing" ] || die "VCS package with empty fingerprint and missing predicted pkgfiles was queued: $empty_pkgfiles_missing"
grep -F -x 'plain-vcs-git: predicted pkgfiles changed without source or VCS changes, skipped' "$empty_pkgfiles_missing_stderr" >/dev/null

rm -f "$packages_dir/plain-vcs-git.sh"

broken_pkgbuild_repo="$tmp_dir/broken-pkgbuild-repo"
mkdir -p "$broken_pkgbuild_repo"
cat >"$broken_pkgbuild_repo/PKGBUILD" <<'EOF'
pkgname=broken-vcs-git
pkgver=1
pkgrel=1
arch=('any')
this is not valid shell syntax
EOF

(
    cd "$broken_pkgbuild_repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name test
    git config commit.gpgsign false
)
git_commit "$broken_pkgbuild_repo" broken
broken_ref=$(cd "$broken_pkgbuild_repo" && git rev-parse --abbrev-ref HEAD)
broken_commit=$(cd "$broken_pkgbuild_repo" && git rev-parse HEAD)

cat >"$packages_dir/broken-vcs-git.sh" <<EOF
# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='broken-vcs-git'

SOURCE_GIT='$broken_pkgbuild_repo'
SOURCE_REF='$broken_ref'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
EOF

: >"$object_dir/$PKG_PREFIX/broken-vcs-git-1-1-any.pkg.tar.zst"
: >"$object_dir/$PKG_PREFIX/broken-vcs-git-1-1-any.pkg.tar.zst.sig"
cat >"$state_dir/broken-vcs-git.env" <<EOF
STATE_VERSION=4
NAME='broken-vcs-git'
SOURCE_GIT='$broken_pkgbuild_repo'
SOURCE_REF='$broken_ref'
LAST_SOURCE_COMMIT='$broken_commit'
PKGNAMES='broken-vcs-git'
PKGFILES='broken-vcs-git-1-1-any.pkg.tar.zst'
RECIPE_FINGERPRINT='old-recipe'
VCS_FINGERPRINT=''
PROBE_VERSION='vcs-probe-v9'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-source-heads-sha256-v1'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

probe_failed_stderr="$tmp_dir/probe-failed.stderr"
probe_failed_queued=$(
    TEST_STATE_DIR=$state_dir \
    TEST_OBJECT_DIR=$object_dir \
    PACKAGES_DIR=$packages_dir \
    PATH=$bin_dir:$PATH \
    sh "$SCRIPT_DIR/check-updates.sh" vcs 2>"$probe_failed_stderr"
)
[ "$probe_failed_queued" = 'broken-vcs-git' ] || die "VCS package with failed probe was not queued: $probe_failed_queued"
grep -F -x 'broken-vcs-git: probe failed, queued' "$probe_failed_stderr" >/dev/null

printf '%s\n' 'vcs probe regression checks passed'
