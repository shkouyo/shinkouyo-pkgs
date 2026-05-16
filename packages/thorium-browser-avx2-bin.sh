# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='thorium-browser-avx2-bin'

SOURCE_GIT='https://aur.archlinux.org/thorium-browser-avx2-bin.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
