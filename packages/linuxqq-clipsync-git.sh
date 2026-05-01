# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='linuxqq-clipsync-git'

SOURCE_GIT='https://aur.archlinux.org/linuxqq-clipsync-git.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
