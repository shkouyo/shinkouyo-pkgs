#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
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

cat >"$tmp_dir/v3.env" <<'EOF'
STATE_VERSION=3
NAME='demo'
SOURCE_GIT='https://example.invalid/demo.git'
SOURCE_REF='main'
LAST_SOURCE_COMMIT='fedcba'
PKGNAMES='demo'
PKGFILES='demo-3-1-any.pkg.tar.zst'
RECIPE_FINGERPRINT='recipe123'
VCS_FINGERPRINT='vcs123'
BUILT_AT='2026-01-03T00:00:00Z'
EOF

cat >"$tmp_dir/v4.env" <<'EOF'
STATE_VERSION=4
NAME='demo'
SOURCE_GIT='https://example.invalid/demo.git'
SOURCE_REF='main'
LAST_SOURCE_COMMIT='123abc'
PKGNAMES='demo'
PKGFILES='demo-4-1-any.pkg.tar.zst'
RECIPE_FINGERPRINT='recipe456'
VCS_FINGERPRINT='vcs456'
PROBE_VERSION='vcs-probe-v8'
RECIPE_FINGERPRINT_KIND='recipe-files-sha256-v1'
VCS_FINGERPRINT_KIND='git-heads-sha256-v1'
BUILT_AT='2026-01-04T00:00:00Z'
EOF

cat >"$tmp_dir/bad-name.env" <<'EOF'
STATE_VERSION=2
NAME='../bad'
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
[ "$RECIPE_FINGERPRINT" = '' ]
[ "$VCS_FINGERPRINT" = '' ]
[ "$PROBE_VERSION" = '' ]
[ "$RECIPE_FINGERPRINT_KIND" = '' ]
[ "$VCS_FINGERPRINT_KIND" = '' ]

eval "$(state_emit_prefixed OLD "$tmp_dir/v2.env")"
[ "$OLD_STATE_VERSION" = '2' ]
[ "$OLD_NAME" = 'demo' ]
[ "$OLD_LAST_SOURCE_COMMIT" = 'def456' ]
[ "$OLD_PKGFILES" = 'demo-2-1-any.pkg.tar.zst' ]
[ "$OLD_RECIPE_FINGERPRINT" = '' ]

eval "$(state_emit_prefixed OLD "$tmp_dir/v3.env")"
[ "$OLD_STATE_VERSION" = '3' ]
[ "$OLD_RECIPE_FINGERPRINT" = 'recipe123' ]
[ "$OLD_VCS_FINGERPRINT" = 'vcs123' ]
[ "$OLD_PROBE_VERSION" = '' ]

eval "$(state_emit_prefixed OLD "$tmp_dir/v4.env")"
[ "$OLD_STATE_VERSION" = '4' ]
[ "$OLD_RECIPE_FINGERPRINT" = 'recipe456' ]
[ "$OLD_VCS_FINGERPRINT" = 'vcs456' ]
[ "$OLD_PROBE_VERSION" = 'vcs-probe-v8' ]
[ "$OLD_RECIPE_FINGERPRINT_KIND" = 'recipe-files-sha256-v1' ]
[ "$OLD_VCS_FINGERPRINT_KIND" = 'git-heads-sha256-v1' ]

if ( state_load "$tmp_dir/bad-name.env" ) >/dev/null 2>&1; then
    die 'state_load accepted an invalid package name'
fi

printf '%s\n' 'state compatibility checks passed'
