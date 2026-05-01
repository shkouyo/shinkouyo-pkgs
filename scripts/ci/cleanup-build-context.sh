#!/bin/sh

set -eu

CI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CI_DIR/../.." && pwd)

. "$ROOT_DIR/scripts/lib/common.sh"

[ "$#" -eq 1 ] || {
    printf 'usage: cleanup-build-context.sh <context_dir>\n' >&2
    exit 1
}

context_dir=$1
workspace=${GITHUB_WORKSPACE:-$ROOT_DIR}
workspace=${workspace%/}

case $workspace in
    /*) ;;
    *) die "GITHUB_WORKSPACE must be absolute: $workspace" ;;
esac

case $context_dir in
    '') die "context_dir is empty" ;;
    /*) ;;
    *) context_dir=$workspace/$context_dir ;;
esac

case $context_dir in
    *'/../'*|*'/..'|'../'*|'..')
        die "refusing to cleanup path with parent traversal: $context_dir"
        ;;
esac

safe_prefix=$workspace/.ci-tmp
case $context_dir in
    "$safe_prefix"/build-?*) ;;
    *) die "refusing to cleanup path outside $safe_prefix/build-*: $context_dir" ;;
esac

[ -e "$context_dir" ] || exit 0

if command -v sudo >/dev/null 2>&1; then
    sudo chmod -R u+rwX "$context_dir" 2>/dev/null || :
    sudo rm -rf -- "$context_dir"
else
    chmod -R u+rwX "$context_dir" 2>/dev/null || :
    rm -rf -- "$context_dir"
fi
