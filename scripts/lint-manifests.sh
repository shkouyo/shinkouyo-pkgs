#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/lib/common.sh"
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
    manifest_load "$manifest"
done
