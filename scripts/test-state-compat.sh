#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$SCRIPT_DIR/state.sh"

tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

cat >"$tmp_dir/v1.env" <<'EOF'
STATE_VERSION=1
NAME='demo'
SOURCE_GIT='https://example.invalid/demo.git'
SOURCE_REF='main'
LAST_SOURCE_COMMIT='abc123'
PKGNAMES='demo'
PKGFILES='demo-1-1-any.pkg.tar.zst'
BUILT_AT='2026-01-01T00:00:00Z'
EOF

cat >"$tmp_dir/v2.env" <<'EOF'
STATE_VERSION=2
NAME='demo'
SOURCE_GIT='https://example.invalid/demo.git'
SOURCE_REF='main'
LAST_SOURCE_COMMIT='def456'
PKGNAMES='demo'
PKGFILES='demo-2-1-any.pkg.tar.zst'
VCS_FINGERPRINT=''
BUILT_AT='2026-01-02T00:00:00Z'
EOF

state_load "$tmp_dir/v1.env"
[ "$NAME" = 'demo' ]
[ "$VCS_FINGERPRINT" = '' ]

eval "$(state_emit_prefixed OLD "$tmp_dir/v2.env")"
[ "$OLD_NAME" = 'demo' ]
[ "$OLD_LAST_SOURCE_COMMIT" = 'def456' ]
[ "$OLD_PKGFILES" = 'demo-2-1-any.pkg.tar.zst' ]

printf '%s\n' 'state compatibility checks passed'
