# Minimal flux-sharness for flux-rest-server
#
# This is a reduced version of flux-core's t/sharness.d/flux-sharness.sh,
# keeping only test_under_flux() and dropping the machinery this project has
# no use for (personality modes and their rc paths, bootstrap config mocking,
# module list checks, test_on_rank, ...), much of which refers to files that
# only exist in the flux-core tree.
#
# The tradeoff is that behavior omitted here is easy to miss: options not
# forwarded to the re-exec'ed script, and broker options not set, are silently
# absent rather than an error.  When something in the testsuite behaves
# differently than it does in flux-core, diff this against the upstream file
# before looking further afield.

export FLUX_EXEC_PATH_PREPEND="${SHARNESS_TEST_SRCDIR}/scripts":"${SHARNESS_TEST_SRCDIR}/../src/cmd"

# Simple test_under_flux that just re-execs under flux start
test_under_flux() {
    size=${1:-1}

    if test -n "$TEST_UNDER_FLUX_ACTIVE" ; then
        return
    fi

    # Name the log after the test (e.g. t1000-basic.broker.log) so it is both
    # identifiable and removed by the *.broker.log rule in clean-local. (Using
    # $TEST_NAME directly yields ".broker.log", a dotfile the glob misses,
    # which then survives distclean and fails distcheck.)
    log_file="$(basename "$0" .t).broker.log"
    flags=""
    if test "$verbose" = "t"; then
        flags="${flags} --verbose"
    fi
    if test "$debug" = "t"; then
        flags="${flags} --debug"
    fi

    # cd to test directory if set (sharness sets this)
    if test -n "$SHARNESS_TEST_DIRECTORY"; then
        cd $SHARNESS_TEST_DIRECTORY
    fi
    logopts="-o -Slog-filename=${log_file} -Slog-forward-level=7"

    TEST_UNDER_FLUX_ACTIVE=t \
      exec flux start --test-size=${size} \
          ${logopts} \
          "sh $0 ${flags}"
}

