# shellcheck disable=all

SCHEMA_VERSION=1
NAME='niri-git'

SOURCE_GIT='https://aur.archlinux.org/niri-git.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
