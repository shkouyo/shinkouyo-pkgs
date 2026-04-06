# shellcheck disable=all

SCHEMA_VERSION=1
NAME='sk-arch-mirrorlist-git'

SOURCE_GIT='https://codeberg.org/shkouyo/sk-arch-mirrorlist.git'
SOURCE_REF='pkgbuild'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=1

build_env() {
    :
}
