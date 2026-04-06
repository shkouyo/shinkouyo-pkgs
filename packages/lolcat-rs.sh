# shellcheck disable=all

SCHEMA_VERSION=1
NAME='lolcat-rs'

SOURCE_GIT='https://aur.archlinux.org/lolcat-rs.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
