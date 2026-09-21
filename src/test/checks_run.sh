#!/bin/bash
#
#  Test runner script meant to be executed inside of a docker container
#
#  Usage: checks_run.sh [OPTIONS...]
#
#  Where OPTIONS are passed directly to ./configure
#
#  The script is otherwise influenced by the following environment variables:
#
#  JOBS=N        Argument for make's -j option, default=2
#  DISTCHECK     Run `make distcheck` if set
#  RECHECK       Run `make recheck` if `make check` fails the first time
#  TEST_INSTALL  Run `make check` against the installed flux-rest-server
#  BUILD_DIR     Name of a subdirectory in which to build (VPATH build)
#  chain_lint    Run sharness with --chain-lint if chain_lint=t
#
#  And, obviously, some crucial variables that configure itself cares about:
#
#  CC, CXX, LDFLAGS, CFLAGS, etc.
#

# source checks_group and related functions:
. src/test/checks-lib.sh

ARGS="$@"
JOBS=${JOBS:-2}
MAKE="make --output-sync=target --no-print-directory"
MAKECMDS="${MAKE} -j ${JOBS}"
CHECKCMDS="${MAKE} -j ${JOBS} ${DISTCHECK:+dist}check"

# Force git to update the shallow clone and include tags so git-describe works
checks_group "git fetch tags" "git fetch --unshallow --tags" \
 git fetch --unshallow --tags || true

checks_group_start "build setup"
ulimit -c unlimited

# Use make install for TEST_INSTALL:
if test "$TEST_INSTALL" = "t"; then
    ARGS="$ARGS --prefix=/usr --sysconfdir=/etc"
    CHECKCMDS="sudo make install && ${MAKE} -j $JOBS check"
fi

# CI has limited resources, even though the number of processors might
#  appear to be large. Limit session size for testing to 5 to avoid
#  spurious timeouts.
export FLUX_TEST_SIZE_MAX=5

# Generate logfiles from sharness tests for extra information:
export FLUX_TESTS_LOGFILE=t
export DISTCHECK_CONFIGURE_FLAGS="${ARGS}"

# The test broker is started with --test-size, which does not need munge, but
# start munged anyway if it is present so that any test that grows a
# munge-authenticated connection does not have to special-case CI.
if test -x /usr/sbin/munged && ! pgrep munged >/dev/null 2>&1; then
    echo "Starting MUNGE"
    sudo runuser -u munge /usr/sbin/munged || true
fi

checks_group_end # Setup

checks_group "autogen.sh" ./autogen.sh

WORKDIR=$(pwd)
if test -n "$BUILD_DIR" ; then
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
fi

checks_group "configure ${ARGS}" ${WORKDIR}/configure ${ARGS} \
	|| (printf "::error::configure failed\n"; cat config.log; exit 1)
checks_group "make clean..." make clean

if test "$DISTCHECK" != "t"; then
  checks_group "${MAKECMDS}" "${MAKECMDS}" \
	|| (printf "::error::${MAKECMDS} failed\n"; exit 1)
fi
checks_group "${CHECKCMDS}" "${CHECKCMDS}"
RC=$?

if test "$RECHECK" = "t" -a $RC -ne 0; then
  #
  # `make recheck` is not recursive, only perform it if at least some tests
  #   under ./t were run (and presumably failed)
  #
  if test -s t/t0000-sharness.trs; then
    cd t
    printf "::warning::make check failed, trying recheck in ./t\n"
    checks_group "make recheck" ${MAKE} -j ${JOBS} recheck
    RC=$?
    cd ..
  else
    printf "::warning::recheck requested but no tests in ./t were run\n"
  fi
fi

exit $RC
