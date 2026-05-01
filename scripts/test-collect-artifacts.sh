#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

bin_dir=$tmp_dir/bin
context_dir=$tmp_dir/context
mkdir -p "$bin_dir" \
    "$context_dir/source" \
    "$context_dir/pkgdest" \
    "$context_dir/srcdest" \
    "$context_dir/makepkg-builddir"

cat >"$bin_dir/gpg" <<'EOF'
#!/bin/sh
case " $* " in
    *" --import "*)
        cat >/dev/null
        exit 0
        ;;
esac

last_arg=
for arg do
    last_arg=$arg
done
[ -n "$last_arg" ] || exit 0
: >"$last_arg.sig"
EOF
chmod +x "$bin_dir/gpg"

cat >"$bin_dir/bsdtar" <<'EOF'
#!/bin/sh
printf '%s\n' 'pkgname = mpvpaper-rs'
EOF
chmod +x "$bin_dir/bsdtar"

pkgfile=$context_dir/pkgdest/mpvpaper-rs-1-1-x86_64.pkg.tar.zst
printf '%s\n' 'fake package payload' >"$pkgfile"
printf '%s\n' 'abcdef1234567890' >"$context_dir/last_source_commit.txt"

cat >"$context_dir/context.env" <<EOF
NAME='mpvpaper-rs'
SOURCE_GIT='https://aur.archlinux.org/mpvpaper-rs.git'
SOURCE_REF='master'
SOURCE_DIR='$context_dir/source'
BUILD_DIR='$context_dir/source/.'
MAKEPKG_BUILDDIR='$context_dir/makepkg-builddir'
PKGDEST='$context_dir/pkgdest'
SRCDEST='$context_dir/srcdest'
PACKAGER='Tester <test@example.invalid>'
BUILD_PKGBUILD='./PKGBUILD'
LAST_SOURCE_COMMIT='abcdef1234567890'
EOF

PATH=$bin_dir:$PATH \
    REPO_NAME=repo \
    S3_BUCKET=bucket \
    S3_ENDPOINT=https://example.invalid \
    S3_REGION=auto \
    AWS_ACCESS_KEY_ID=key \
    AWS_SECRET_ACCESS_KEY=secret \
    GPG_PRIVATE_KEY=private \
    GPG_KEY_ID=keyid \
    sh "$ROOT_DIR/scripts/build.sh" collect "$context_dir"

[ -f "$context_dir/vcs_fingerprint.txt" ] || die 'collect did not create vcs_fingerprint.txt'
[ ! -s "$context_dir/vcs_fingerprint.txt" ] || die 'non-VCS collect wrote a non-empty VCS fingerprint'
[ -f "$context_dir/recipe_fingerprint.txt" ] || die 'collect did not create recipe_fingerprint.txt'
[ -f "$context_dir/state.env" ] || die 'collect did not create state.env'
[ -f "$pkgfile.sig" ] || die 'collect did not sign package artifact'

grep -F -x "VCS_FINGERPRINT=''" "$context_dir/state.env" >/dev/null ||
    die 'state.env did not preserve empty VCS_FINGERPRINT'
grep -F -x "PKGFILES='mpvpaper-rs-1-1-x86_64.pkg.tar.zst'" "$context_dir/state.env" >/dev/null ||
    die 'state.env did not include collected package file'

printf '%s\n' 'collect artifact checks passed'
