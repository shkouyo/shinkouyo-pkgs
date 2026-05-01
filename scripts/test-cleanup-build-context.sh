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
workspace=$tmp_dir/workspace
mkdir -p "$bin_dir" "$workspace"

cat >"$bin_dir/sudo" <<'EOF'
#!/bin/sh
log=${SUDO_LOG:?}
printf '%s\n' "$*" >>"$log"
exec "$@"
EOF
chmod +x "$bin_dir/sudo"

sudo_log=$tmp_dir/sudo.log
target=$workspace/.ci-tmp/build-demo
mkdir -p "$target/nested"
printf '%s\n' data >"$target/nested/file"

PATH=$bin_dir:$PATH SUDO_LOG=$sudo_log GITHUB_WORKSPACE=$workspace \
    sh "$ROOT_DIR/scripts/ci/cleanup-build-context.sh" "$target"

[ ! -e "$target" ] || die "cleanup did not remove valid build context"
grep -F -q -- "rm -rf -- $target" "$sudo_log" || die "cleanup did not use sudo rm"

missing=$workspace/.ci-tmp/build-missing
PATH=$bin_dir:$PATH SUDO_LOG=$sudo_log GITHUB_WORKSPACE=$workspace \
    sh "$ROOT_DIR/scripts/ci/cleanup-build-context.sh" "$missing"

if PATH=$bin_dir:$PATH SUDO_LOG=$sudo_log GITHUB_WORKSPACE=$workspace \
    sh "$ROOT_DIR/scripts/ci/cleanup-build-context.sh" "$workspace/not-ci-tmp" >/dev/null 2>&1; then
    die "cleanup accepted a path outside .ci-tmp/build-*"
fi

if PATH=$bin_dir:$PATH SUDO_LOG=$sudo_log GITHUB_WORKSPACE=$workspace \
    sh "$ROOT_DIR/scripts/ci/cleanup-build-context.sh" "$workspace/.ci-tmp/build-demo/../other" >/dev/null 2>&1; then
    die "cleanup accepted parent traversal"
fi

printf '%s\n' 'cleanup build context checks passed'
