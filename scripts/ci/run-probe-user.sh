#!/bin/sh

set -eu

CI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CI_DIR/../.." && pwd)

. "$ROOT_DIR/scripts/lib/common.sh"

[ "$#" -ge 1 ] || {
    printf 'usage: run-probe-user.sh <command> [args...]\n' >&2
    exit 1
}

probe_user='ci-probe'
probe_home="${RUNNER_TEMP:-/tmp}/$probe_user-home"
probe_tmp="${RUNNER_TEMP:-/tmp}/$probe_user-tmp"
mkdir -p "$probe_tmp"

if [ "$(id -u)" != '0' ]; then
    log "probe helper: current user is not root, running without user switch"
    env HOME="$probe_home" TMPDIR="$probe_tmp" "$@"
    exit 0
fi

if ! id "$probe_user" >/dev/null 2>&1; then
    useradd --create-home --home-dir "$probe_home" --shell /bin/sh "$probe_user"
fi

chown -R "$probe_user:$probe_user" "$probe_home" "$probe_tmp"

escaped_args=''
for arg in "$@"; do
    escaped_args="${escaped_args}${escaped_args:+ }$(shell_quote "$arg")"
done

env HOME="$probe_home" TMPDIR="$probe_tmp" su -m "$probe_user" -s /bin/sh -c "
    set -eu
    cd $(shell_quote "$ROOT_DIR")
    printf 'probe_user=%s uid=%s home=%s tmpdir=%s\n' \"\$(id -un)\" \"\$(id -u)\" \"\$HOME\" \"\${TMPDIR-}\" >&2
    exec $escaped_args
"
