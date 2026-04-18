#!/bin/sh

set -eu

CI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CI_DIR/../.." && pwd)

. "$ROOT_DIR/scripts/lib/common.sh"

[ "$#" -eq 2 ] || {
    printf 'usage: prepare-build-context.sh <manifest> <context_dir>\n' >&2
    exit 1
}

manifest_path=$1
context_dir=$2

sh "$ROOT_DIR/scripts/build.sh" prepare "$manifest_path" "$context_dir"
cat "$context_dir/github.env" >>"$GITHUB_ENV"

# shellcheck disable=SC1090
. "$context_dir/context.env"
action_path=$(printf '%s\n' "$BUILD_DIR" | sed "s#^$GITHUB_WORKSPACE/##")

printf 'context_dir=%s\n' "$context_dir" >>"$GITHUB_OUTPUT"
printf 'build_dir=%s\n' "$BUILD_DIR" >>"$GITHUB_OUTPUT"
printf 'action_path=%s\n' "$action_path" >>"$GITHUB_OUTPUT"
