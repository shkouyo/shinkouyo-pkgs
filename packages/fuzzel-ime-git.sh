# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='fuzzel-ime-git'

SOURCE_GIT='https://aur.archlinux.org/fuzzel-ime-git.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
