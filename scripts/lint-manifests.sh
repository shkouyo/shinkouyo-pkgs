#!/bin/sh

set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$SCRIPT_DIR/manifest.sh"

usage() {
    printf 'usage: lint-manifests.sh [manifest...]\n' >&2
    exit 1
}

if [ "$#" -eq 0 ]; then
    set -- "$ROOT_DIR"/packages/*.sh
fi

for manifest in "$@"; do
    [ -f "$manifest" ] || usage
    is_template_manifest "$manifest" && continue
    manifest_load "$manifest"
done
