# shellcheck shell=sh

SCHEMA_VERSION=1
NAME='mkinitcpio-archiso-ventoy'

SOURCE_GIT='https://aur.archlinux.org/mkinitcpio-archiso-ventoy.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
