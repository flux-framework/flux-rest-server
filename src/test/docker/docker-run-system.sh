#!/bin/bash
#
#  Run the flux-rest-server system tests (t/t2*.t) against a real Flux system
#  instance, booted in a podman container.
#
#  Usage: docker-run-system.sh [OPTIONS]
#
#  Unlike docker-run-checks.sh, this needs a container running systemd as PID 1
#  (socket activation, polkit and per-user setuid are the things under test), so
#  it uses podman rather than docker.  podman is the only container runtime
#  required; flux-core is consumed from its published image, not rebuilt.
#
#  The default image is el10 because fluxrm/flux-core:el10 is published as a
#  multi-arch manifest: this then runs natively on an arm64 developer machine
#  rather than under emulation, which is the difference between a few minutes
#  and a timeout.  Pass --image to test another base.
#
#  The container is privileged and bind-mounts the host's /sys/fs/cgroup.  On an
#  Ubuntu host the AppArmor profiles for sudo and unix-chkpwd also have to be
#  unloaded for PAM to work inside the container; this script does NOT do that
#  to your machine.  CI does it explicitly in .github/workflows/main.yml.
#
PROJECT=flux-rest-server
WORKDIR=/usr/src
IMAGE=fluxrm/flux-core:el10
JOBS=2

declare -r prog=${0##*/}
die() { echo -e "$prog: $@" >&2; exit 1; }

declare -r long_opts="help,jobs:,image:,interactive,no-cache"
declare -r short_opts="hj:i:I"
declare -r usage="
Usage: $prog [OPTIONS]\n\
Boot a Flux system instance in a podman container and run the system tests.\n\
\n\
Options:\n\
 -h, --help              Display this message\n\
 -j, --jobs=N            Value for make -j (default=$JOBS)\n\
 -i, --image=NAME        Base flux-core image (default=$IMAGE)\n\
 -I, --interactive       Install, then run a shell instead of the tests\n\
     --no-cache          Run podman build with --no-cache\n\
"

GETOPTS=$(/usr/bin/getopt -u -o $short_opts -l $long_opts -n $prog -- "$@") \
    || die "$usage"
eval set -- "$GETOPTS"

while true; do
    case "$1" in
      -h|--help)        echo -ne "$usage";     exit 0  ;;
      -j|--jobs)        JOBS="$2";             shift 2 ;;
      -i|--image)       IMAGE="$2";            shift 2 ;;
      -I|--interactive) INTERACTIVE=t;         shift   ;;
      --no-cache)       NOCACHE="--no-cache";  shift   ;;
      --)               shift; break                   ;;
      *)                die "Invalid option '$1'\n$usage" ;;
    esac
done

TOP=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside the $PROJECT git repository!"
command -v podman >/dev/null \
    || die "podman is required to run the system tests"

. ${TOP}/src/test/checks-lib.sh

#  Tag per base image, so alternating --image does not silently reuse an image
#  built from a different base.
TAG=flux-rest-server-systest:$(printf %s "${IMAGE##*[:/]}" | tr -c '[:alnum:]_.-' '-')
NAME=flux-rest-server-system-$$

checks_group "Building $TAG from $IMAGE" \
  sudo podman build \
    ${NOCACHE} \
    --build-arg IMAGESRC=$IMAGE \
    --build-arg USER=$USER \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) \
    -t $TAG \
    ${TOP}/src/test/docker/system \
    || die "podman build failed"

#  Always tear the container down, however we leave: a failed test, a hung
#  podman exec, or a cancelled CI job.
cleanup() { sudo podman rm -f $NAME >/dev/null 2>&1; }
trap cleanup EXIT

#  --privileged/--systemd=always/cgroup mount/apparmor=unconfined are what it
#  takes to run systemd, logind and user@.service inside a container; this is
#  flux-core's incantation and is not worth re-deriving.
#
#  No --network=host: the tests run inside the container via podman exec, so
#  nginx on :8080 never needs to be reachable from the host.
checks_group "Launching system instance container $NAME" \
  sudo podman run -d \
    --name=$NAME \
    --privileged \
    --systemd=always \
    --volume=/sys/fs/cgroup:/sys/fs/cgroup:rw \
    --security-opt apparmor=unconfined \
    --hostname=fluxorama \
    --volume=$TOP:$WORKDIR \
    --workdir=$WORKDIR \
    $TAG \
    || die "podman run failed"

#  Wait for the system instance to come up.
TIMEOUT=180
checks_group_start "Waiting for flux.service (up to ${TIMEOUT}s)"
i=0
while ! sudo podman exec $NAME systemctl is-active --quiet flux.service; do
    i=$((i + 5))
    if test $i -ge $TIMEOUT; then
        echo "=== systemctl status flux.service ==="
        sudo podman exec $NAME systemctl status flux.service --no-pager -l 2>&1
        echo "=== journal ==="
        sudo podman exec $NAME journalctl --no-pager -n 200 2>&1
        checks_group_end
        die "flux.service failed to start within ${TIMEOUT}s"
    fi
    sleep 5
done
echo "flux.service active after ${i}s"
checks_group_end

#  Forward the variables the testsuite cares about, from one list, and only if
#  they are actually set.  (A wall of `-e VAR=$VAR` passes empty strings for
#  unset variables and drifts out of sync with the rest of the CI scripts.)
env_args=(-e "HOME=/home/$USER")
for var in JOBS USER PROJECT CI TAP_DRIVER_QUIET \
           FLUX_TEST_TIMEOUT FLUX_TESTS_LOGFILE \
           debug verbose chain_lint; do
    if test -n "${!var}"; then
        env_args+=(-e "$var=${!var}")
    fi
done

if test -n "$INTERACTIVE"; then
    #  Install and configure first, so the shell lands in a system instance
    #  running the current code rather than an empty one.
    checks_group "Installing flux-rest-server" \
      sudo podman exec -u $USER "${env_args[@]}" -w $WORKDIR \
        $NAME src/test/system_run.sh --setup-only \
        || die "setup failed"
    sudo podman exec -ti -u $USER "${env_args[@]}" -w $WORKDIR $NAME bash
    exit $?
fi

checks_group "Running system tests" \
  sudo podman exec -u $USER "${env_args[@]}" -w $WORKDIR \
    $NAME src/test/system_run.sh
RC=$?

test $RC -eq 0 || die "system tests failed with rc=$RC"

# vi: ts=4 sw=4 expandtab
