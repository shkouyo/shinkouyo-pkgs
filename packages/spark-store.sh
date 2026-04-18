# shellcheck disable=all

SCHEMA_VERSION=1
NAME='spark-store'

SOURCE_GIT='https://aur.archlinux.org/spark-store.git'
SOURCE_REF='master'

BUILD_WORKDIR='.'
BUILD_PKGBUILD='./PKGBUILD'

UPDATE_ENABLED=1
UPDATE_VCS=0

build_env() {
    :
}
