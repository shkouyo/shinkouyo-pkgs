# shellcheck disable=all

SCHEMA_VERSION=1
NAME='fluent-icon-theme-git'

SOURCE_GIT='https://aur.archlinux.org/fluent-icon-theme-git.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
