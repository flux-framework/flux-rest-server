#!/bin/bash
#
#  Build flux-rest-server "checks" docker image and run tests, exporting
#   important environment variables to the docker environment.
#
#  Arguments here are passed directly to ./configure
#
#
# option Defaults:
PROJECT=flux-rest-server
BASE_DOCKER_REPO=fluxrm/flux-core

WORKDIR=/usr/src
IMAGE=noble
JOBS=2
MOUNT_HOME_ARGS="--volume=$HOME:/home/$USER -e HOME"

#
declare -r prog=${0##*/}
die() { echo -e "$prog: $@"; exit 1; }

#
declare -r long_opts="help,quiet,interactive,image:,jobs:,no-cache,no-home,distcheck,tag:,build-directory:,install-only,recheck,platform:,workdir:,build-arg:"
declare -r short_opts="hqIdi:j:t:D:rp:"
declare -r usage="
Usage: $prog [OPTIONS] -- [CONFIGURE_ARGS...]\n\
Build docker image for CI builds, then run tests inside the new\n\
container as the current user and group.\n\
\n\
Uses the current git repo for the build.\n\
\n\
Options:\n\
 -h, --help                    Display this message\n\
     --no-cache                Disable docker caching\n\
     --no-home                 Skip mounting the host home directory\n\
     --install-only            Skip make check, only make install\n\
     --build-arg ARG=VAL       Add extra --build-args to docker build\n\
 -q, --quiet                   Add --quiet to docker-build\n\
 -t, --tag=TAG                 If checks succeed, tag image as NAME\n\
 -i, --image=NAME              Use base docker image NAME (default=$IMAGE)\n\
 -p, --platform=NAME           Run on alternate platform (if supported)\n\
 -j, --jobs=N                  Value for make -j (default=$JOBS)\n\
 -d, --distcheck               Run 'make distcheck' instead of 'make check'\n\
 -r, --recheck                 Run 'make recheck' after failure\n\
 -D, --build-directory=DIRNAME Name of a subdir to build in, will be made\n\
     --workdir=PATH            Use PATH as working directory for build\n\
 -I, --interactive             Instead of running ci build, run docker\n\
                                image with interactive shell.\n\
"

# check if running in OSX
if [[ "$(uname)" == "Darwin" ]]; then
    # BSD getopt
    GETOPTS=`/usr/bin/getopt $short_opts -- $*`
else
    # GNU getopt
    GETOPTS=`/usr/bin/getopt -u -o $short_opts -l $long_opts -n $prog -- $@`
    if [[ $? != 0 ]]; then
        die "$usage"
    fi
    eval set -- "$GETOPTS"
fi
while true; do
    case "$1" in
      -h|--help)                   echo -ne "$usage";          exit 0  ;;
      -q|--quiet)                  QUIET="--quiet";            shift   ;;
      -i|--image)                  IMAGE="$2";                 shift 2 ;;
      -p|--platform)               PLATFORM="--platform=$2";   shift 2 ;;
      -j|--jobs)                   JOBS="$2";                  shift 2 ;;
      -I|--interactive)            INTERACTIVE="/bin/bash";    shift   ;;
      -d|--distcheck)              DISTCHECK=t;                shift   ;;
      -r|--recheck)                RECHECK=t;                  shift   ;;
      -D|--build-directory)        BUILD_DIR="$2";             shift 2 ;;
      --workdir)                   WORKDIR="$2";               shift 2 ;;
      --no-cache)                  NO_CACHE="--no-cache";      shift   ;;
      --no-home)                   MOUNT_HOME_ARGS="";         shift   ;;
      --install-only)              INSTALL_ONLY=t;             shift   ;;
      -t|--tag)                    TAG="$2";                   shift 2 ;;
      --build-arg)                 BUILD_ARG="$BUILD_ARG --build-arg $2"
                                                               shift 2 ;;
      --)                          shift; break;                       ;;
      *)                           die "Invalid option '$1'\n$usage"   ;;
    esac
done

TOP=$(git rev-parse --show-toplevel 2>&1) \
    || die "not inside $PROJECT git repository!"
which docker >/dev/null \
    || die "unable to find a docker binary"
if docker buildx >/dev/null 2>&1; then
    DOCKER_BUILD="docker buildx build --load"
else
    DOCKER_BUILD="docker build"
fi

# distcheck incompatible with some configure args
if test "$DISTCHECK" = "t"; then
    test "$RECHECK" = "t" && die "--recheck not allowed with --distcheck"
    for arg in "$@"; do
        case $arg in
          --sysconfdir=*|--with-systemdsystemunitdir=*)
            die "distcheck incompatible with configure arg $arg"
        esac
    done
fi

CONFIGURE_ARGS="$@"

. ${TOP}/src/test/checks-lib.sh

BUILD_IMAGE=checks-builder:${IMAGE}
DOCKERFILE=$TOP/src/test/docker/$IMAGE
test -d "$DOCKERFILE" || die "no Dockerfile for image '$IMAGE'"

checks_group "Building image $IMAGE for user $USER $(id -u) group=$(id -g)" \
  ${DOCKER_BUILD} \
    ${PLATFORM} \
    ${NO_CACHE} \
    ${QUIET} \
    --build-arg IMAGESRC="$BASE_DOCKER_REPO:$IMAGE" \
    --build-arg USER=$USER \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) \
    ${BUILD_ARG} \
    -t ${BUILD_IMAGE} \
    ${DOCKERFILE} \
    || die "docker build failed"

if [[ -n "$MOUNT_HOME_ARGS" ]]; then
    echo "mounting $HOME as /home/$USER"
fi
echo "mounting $TOP as $WORKDIR"

export PROJECT
export JOBS
export DISTCHECK
export RECHECK
export BUILD_DIR
export chain_lint

if [[ "$INSTALL_ONLY" == "t" ]]; then
    docker run --rm \
        --workdir=$WORKDIR \
        --volume=$TOP:$WORKDIR \
        ${PLATFORM} \
        ${BUILD_IMAGE} \
        sh -c "./autogen.sh &&
               ./configure --prefix=/usr --sysconfdir=/etc \
                --with-systemdsystemunitdir=/etc/systemd/system \
                --localstatedir=/var &&
               make clean &&
               make -j${JOBS}" \
    || die "docker run of 'make install' failed"
else
    docker run --rm \
        --workdir=$WORKDIR \
        --volume=$TOP:$WORKDIR \
        ${PLATFORM} \
        $MOUNT_HOME_ARGS \
        -e CC \
        -e CXX \
        -e LDFLAGS \
        -e CFLAGS \
        -e CPPFLAGS \
        -e COVERAGE \
        -e DISTCHECK \
        -e RECHECK \
        -e TEST_INSTALL \
        -e chain_lint \
        -e JOBS \
        -e USER \
        -e PROJECT \
        -e CI \
        -e TAP_DRIVER_QUIET \
        -e TEST_CHECK_PREREQS \
        -e FLUX_TEST_TIMEOUT \
        -e FLUX_TEST_SIZE_MAX \
        -e FLUX_TESTS_LOGFILE \
        -e BUILD_DIR \
        -e debug \
        -e verbose \
        --cap-add SYS_PTRACE \
        --tty \
        ${INTERACTIVE:+--interactive} \
        --network=host \
        ${BUILD_IMAGE} \
        ${INTERACTIVE:-./src/test/checks_run.sh ${CONFIGURE_ARGS}} \
    || die "docker run failed"
fi

if test -n "$TAG"; then
    # Re-run 'make install' in fresh image, otherwise we get all
    # the context from the build above
    docker run --name=tmp.$$ \
        --workdir=${WORKDIR}/${BUILD_DIR} \
        --volume=$TOP:${WORKDIR} \
        --user="root" \
        ${PLATFORM} \
        ${BUILD_IMAGE} \
        sh -c "make install && userdel $USER" \
        || (docker rm tmp.$$; die "docker run of 'make install' failed")
    docker commit \
        --change 'USER fluxuser' \
        --change 'WORKDIR /home/fluxuser' \
        tmp.$$ $TAG \
        || die "docker commit failed"
    docker rm tmp.$$
    echo "Tagged image $TAG"
fi
