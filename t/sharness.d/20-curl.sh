##
# Common curl options for the testsuite.
#
# Every curl invocation needs a timeout.  An unbounded client-side stall burns
# the whole FLUX_TEST_TIMEOUT, which kills the test script mid-stream, so the
# file is reported as "missing test plan" rather than as a failed test.
#
# Tests that expect curl to fail must assert a specific exit code, so that a
# timeout (exit 28) can never be mistaken for the failure under test.
##
CURL_TIMEOUT_ARGS="--connect-timeout 10 --max-time 60"
