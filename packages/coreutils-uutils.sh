# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='coreutils-uutils'

SOURCE_GIT='https://codeberg.org/shkouyo/pkgbuilds.git'
SOURCE_REF='coreutils-uutils'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
