#!/bin/sh

test_description='Test that SIGTERM/SIGINT does not truncate an in-flight response'

. $(dirname $0)/sharness.sh

test_under_flux 1

SERVER_PY="${SHARNESS_TEST_SRCDIR}/../src/cmd/flux-rest-server.py"
MIDREQUEST="${SHARNESS_TEST_SRCDIR}/scripts/stop_midrequest.py"

# Start a server on its own socket as a direct child, so the test has a pid to
# signal.  t1000/t1001 use `flux exec --bg`, which does not expose one.  The
# socket goes in the rundir rather than $(pwd): the deep distcheck build path
# would exceed the AF_UNIX sun_path length limit.  Output is redirected to a
# file, not inherited -- a server that outlives a failing test would otherwise
# hold the test driver's pipe open and hang the whole suite.  Returns once the
# server is answering, with $server_pid and $server_sock set.
start_server() {
	local name=$1
	local tries=50

	shift
	server_sock="$(flux getattr rundir)/${name}.sock"
	flux rest-server --socket "$server_sock" "$@" >${name}.log 2>&1 &
	server_pid=$!
	test_when_finished 'kill -9 $server_pid 2>/dev/null; true'

	while test $tries -gt 0; do
		curl ${CURL_TIMEOUT_ARGS} -sf --unix-socket "$server_sock" \
		    http://localhost/api/v1/health >/dev/null 2>&1 && return 0
		tries=$((tries-1))
		sleep 0.1
	done
	return 1
}

# Wait for $1 to exit and return its status.  $2 bounds the wait in tenths of a
# second (default 5s); exceeding it returns 125 rather than blocking, so a
# server that will not stop fails this test instead of stalling the script until
# FLUX_TEST_TIMEOUT kills it -- which reports the file as "missing test plan"
# rather than as a failure (see sharness.d/20-curl.sh for the same trap).
wait_for_exit() {
	local pid=$1
	local tries=${2:-50}

	while test $tries -gt 0; do
		kill -0 $pid 2>/dev/null || break
		tries=$((tries-1))
		sleep 0.1
	done
	test $tries -gt 0 || return 125
	wait $pid
}

test_expect_success 'SIGTERM stops the server with exit status 0' '
	start_server term &&
	kill -TERM $server_pid &&
	wait_for_exit $server_pid
'

# The serve loop blocks in select() for up to --idle-timeout at a stretch, and a
# signal that only sets a flag cannot cut that short: the server would linger
# for the whole timeout.  The shipped systemd unit uses 5m, well past the
# default TimeoutStopSec, so it would be SIGKILLed.  1h here so that a
# regression cannot pass by merely being slow.
test_expect_success 'SIGTERM does not wait out a pending --idle-timeout' '
	start_server idle --idle-timeout=1h &&
	kill -TERM $server_pid &&
	wait_for_exit $server_pid
'

# Hold a connection open to $1 without sending a request, parking the server in
# rfile.readline().  Returns once the connection is established.
stall_client() {
	local tries=50

	flux python -c "
import socket, sys, time

s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
sys.stderr.write('connected\n')
sys.stderr.flush()
time.sleep(3600)
" "$1" 2>stall.err &
	stall_pid=$!
	test_when_finished 'kill -9 $stall_pid 2>/dev/null; true'

	while test $tries -gt 0; do
		grep -q connected stall.err 2>/dev/null && return 0
		tries=$((tries-1))
		sleep 0.1
	done
	return 1
}

# Handler.timeout is None, so a client that connects and never sends a request
# occupies the handler indefinitely.  Letting an in-flight request finish must
# therefore be a bounded wait (_STOP_GRACE), or this client could hold the
# server open until systemd resorts to SIGKILL.  Allow 15s for a 5s grace.
test_expect_success 'SIGTERM completes despite a client that sends nothing' '
	start_server stall &&
	stall_client "$server_sock" &&
	kill -TERM $server_pid &&
	wait_for_exit $server_pid 150
'

# The bug itself (issue #27): a signal that unwinds through the request handler
# leaves the client with a partial body, or none at all.  Needs a slow route
# with a large response to open the window reliably, so it runs out of process
# against the server module rather than through curl; see the script.
test_expect_success 'a response in flight when SIGTERM arrives is not truncated' '
	flux python "$MIDREQUEST" "$SERVER_PY" \
	    "$(flux getattr rundir)/mid-term.sock" 15
'

test_expect_success 'a response in flight when SIGINT arrives is not truncated' '
	flux python "$MIDREQUEST" "$SERVER_PY" \
	    "$(flux getattr rundir)/mid-int.sock" 2
'

# The server honors an inherited SIG_IGN for SIGINT, which is what a
# non-interactive shell sets for a background job: an interactive Ctrl-C, which
# reaches the whole process group in a shell without job control, must not stop
# a server that was deliberately backgrounded.  SIGTERM is unconditional.
test_expect_success 'a backgrounded server is not stopped by SIGINT' '
	start_server ignint &&
	kill -INT $server_pid &&
	sleep 1 &&
	kill -0 $server_pid &&
	kill -TERM $server_pid &&
	wait_for_exit $server_pid
'

test_done
