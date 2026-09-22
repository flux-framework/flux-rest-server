#!/bin/sh

test_description='Test that a stalled client cannot wedge the serve loop'

. $(dirname $0)/sharness.sh

test_under_flux 1

SERVER_PY="${SHARNESS_TEST_SRCDIR}/../src/cmd/flux-rest-server.py"
STALLED="${SHARNESS_TEST_SRCDIR}/scripts/stalled_client.py"

# The shipped Handler.timeout is 30s, too long to wait out in a test, so this
# drives the server module out of process with a short one -- which also lets
# the check assert how long the second client waited, not just that it was
# eventually served. It asserts the shipped default is set before overriding
# it. Ordinary requests under the real value are covered by t1000-t1005, which
# all run a normally started server.
test_expect_success 'a client that sends nothing does not wedge the server' '
	flux python "$STALLED" "$SERVER_PY" \
	    "$(flux getattr rundir)/stalled.sock"
'

test_done
