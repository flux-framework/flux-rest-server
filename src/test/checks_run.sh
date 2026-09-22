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
#  COVERAGE      Collect Python coverage during `make check` if set
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
POSTCHECKCMDS=":"

# Force git to update the shallow clone and include tags so git-describe works
checks_group "git fetch tags" "git fetch --unshallow --tags" \
 git fetch --unshallow --tags || true

checks_group_start "build setup"
ulimit -c unlimited

# Collect Python coverage.  Everything this project ships is Python, so there
# is no --enable-code-coverage/lcov half here as in the C flux projects.
#
# The subprocesses that need measuring (`flux rest-server`, the _ensure helper)
# are started by the testsuite, not by us, so coverage has to start itself in
# every interpreter: COVERAGE_PROCESS_START plus a customize module that calls
# coverage.process_startup().
#
# The other flux projects install that module as usercustomize.py under
# site.USER_SITE, but that does not work here: sharness resets HOME to the
# per-test trash directory, which moves USER_SITE with it, so the module is
# never found.  Put it on PYTHONPATH instead, which survives the HOME change.
# It is named usercustomize.py rather than sitecustomize.py deliberately -- the
# Debian/Ubuntu images ship a real /usr/lib/python3*/sitecustomize.py that a
# PYTHONPATH entry of the same name would shadow.
#
# PYTHONPATH also needs the directory coverage itself was installed into: the
# scripts run under flux-core's interpreter via `flux python`, which is not
# necessarily the one pip installed coverage for.
if test "$COVERAGE" = "t"; then
	export PATH=~/.local/bin/:$PATH

	# install coverage via pip if necessary
	coverage -h >/dev/null 2>&1 \
	    || python3 -m pip install --user coverage \
	    || python3 -m pip install --user --break-system-packages coverage

	COVERAGE_SITEDIR=$(pwd)/coverage-site
	mkdir -p ${COVERAGE_SITEDIR}
	cat <<-EOF >${COVERAGE_SITEDIR}/usercustomize.py
	try:
	    import coverage
	    coverage.process_startup()
	except ImportError:
	    pass
	EOF

	# Directory coverage is importable from, to add to PYTHONPATH:
	COVERAGE_PKGDIR=$(python3 -c \
	    'import coverage, os; print(os.path.dirname(os.path.dirname(coverage.__file__)))')

	# relative_files=True keeps paths in the report relative to the source
	# tree, so they match for codecov regardless of where the build ran.
	cat <<-EOF >coverage.rc
	[run]
	data_file = $(pwd)/.coverage
	include = $(pwd)/src/*
	parallel = True
	relative_files = True
	EOF

	rm -f .coverage .coverage.* coverage.xml

	CHECKCMDS="\
	PYTHONPATH=${COVERAGE_SITEDIR}:${COVERAGE_PKGDIR} \
	COVERAGE_PROCESS_START=$(pwd)/coverage.rc \
	${MAKE} -j ${JOBS} check"
	POSTCHECKCMDS="\
	coverage combine .coverage* && \
	coverage html && \
	coverage xml && \
	chmod 444 coverage.xml && \
	(coverage report || :)"

# Use make install for TEST_INSTALL:
elif test "$TEST_INSTALL" = "t"; then
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

# Generate the coverage report (a no-op unless COVERAGE=t).  Only on success:
# after a failure the run is incomplete, so the numbers would be misleading.
if test $RC -eq 0; then
  checks_group "${POSTCHECKCMDS}" "${POSTCHECKCMDS}"
  RC=$?
fi

exit $RC
