# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='v2rayn-bin'

SOURCE_GIT='https://aur.archlinux.org/v2rayn-bin.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
