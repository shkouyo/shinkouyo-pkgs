# shellcheck disable=all

SCHEMA_VERSION=1
NAME='shorinclip-git'

SOURCE_GIT='https://aur.archlinux.org/shorinclip-git.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
