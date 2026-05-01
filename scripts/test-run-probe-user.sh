#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"

require_cmd mktemp

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

write_fake_root_tools() {
    bin_dir=$1

    mkdir -p "$bin_dir"

    cat >"$bin_dir/id" <<'EOF'
#!/bin/sh

case ${1-} in
    -u)
        printf '%s\n' 0
        ;;
    -un)
        printf '%s\n' ci-probe
        ;;
    ci-probe)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF

    cat >"$bin_dir/useradd" <<'EOF'
#!/bin/sh
exit 1
EOF

    cat >"$bin_dir/chown" <<'EOF'
#!/bin/sh
exit 0
EOF

    cat >"$bin_dir/su" <<'EOF'
#!/bin/sh

set -eu

[ "$#" -eq 6 ] || exit 2
[ "$1" = "-m" ] || exit 2
[ "$2" = "-s" ] || exit 2
[ "$3" = "/bin/sh" ] || exit 2
[ "$4" = "-c" ] || exit 2
[ "$6" = "ci-probe" ] || exit 2

exec /bin/sh -c "$5"
EOF

    chmod +x "$bin_dir/id" "$bin_dir/useradd" "$bin_dir/chown" "$bin_dir/su"
}

write_fake_nonroot_id() {
    bin_dir=$1

    mkdir -p "$bin_dir"
    cat >"$bin_dir/id" <<'EOF'
#!/bin/sh

case ${1-} in
    -u)
        printf '%s\n' 1000
        ;;
    *)
        command id "$@"
        ;;
esac
EOF

    chmod +x "$bin_dir/id"
}

root_bin="$tmp_dir/root-bin"
root_stdout="$tmp_dir/root.stdout"
root_stderr="$tmp_dir/root.stderr"
write_fake_root_tools "$root_bin"

PATH=$root_bin:$PATH RUNNER_TEMP="$tmp_dir/root-temp" \
    sh "$ROOT_DIR/scripts/ci/run-probe-user.sh" sh -c 'printf "%s:%s:%s\n" "$HOME" "$TMPDIR" "$PWD"' \
    >"$root_stdout" 2>"$root_stderr"

grep -F -x "$tmp_dir/root-temp/ci-probe-home:$tmp_dir/root-temp/ci-probe-tmp:$ROOT_DIR" "$root_stdout" >/dev/null
grep -F 'probe_user=ci-probe uid=0 home='"$tmp_dir"'/root-temp/ci-probe-home tmpdir='"$tmp_dir"'/root-temp/ci-probe-tmp' "$root_stderr" >/dev/null

nonroot_bin="$tmp_dir/nonroot-bin"
nonroot_stderr="$tmp_dir/nonroot.stderr"
write_fake_nonroot_id "$nonroot_bin"

if PATH=$nonroot_bin:$PATH RUNNER_TEMP="$tmp_dir/nonroot-temp" \
    sh "$ROOT_DIR/scripts/ci/run-probe-user.sh" sh -c 'exit 7' >/dev/null 2>"$nonroot_stderr"; then
    die "run-probe-user.sh hid a non-root child failure"
else
    status=$?
fi

[ "$status" -eq 7 ] || die "expected non-root child failure status 7, got $status"
grep -F -x 'probe helper: current user is not root, running without user switch' "$nonroot_stderr" >/dev/null

printf '%s\n' 'run-probe-user checks passed'
