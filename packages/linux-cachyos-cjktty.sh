# shellcheck disable=all

SCHEMA_VERSION=1
NAME='linux-cachyos-cjktty'

SOURCE_GIT='https://aur.archlinux.org/linux-cachyos-cjktty.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    export _build_zfs=yes
}
