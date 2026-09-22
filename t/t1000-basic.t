#!/bin/sh

test_description='Test basic operation and endpoints with server logging'

. $(dirname $0)/sharness.sh

test_under_flux 1

REST_SOCKET="$(flux getattr rundir)/rest"
CURL="curl ${CURL_TIMEOUT_ARGS} --unix-socket ${REST_SOCKET}"

# Start the server as a background process.
# Return only after the server is responding to requests
# N.B. --verbose logs request telemetry to stdout (LOG_INFO via flux exec)
start_server() {
	local tries=50

	flux exec -r 0 --bg flux rest-server --verbose || return 1

	while test $tries -gt 0; do
		$CURL -sf http://localhost/api/v1/ && return 0
		tries=$(($tries-1))
		sleep 0.1
	done
	return 1
}

test_expect_success 'start flux-rest-server' '
	start_server
'

test_expect_success 'health endpoint returns 200' '
	$CURL -sf http://localhost/api/v1/health >health.out &&
	jq -e ".status == \"ok\"" health.out
'

test_expect_success 'root endpoint returns instance info' '
	$CURL -sf http://localhost/api/v1/ >root.out &&
	jq -e .name root.out &&
	jq -e ".user == \"$(id -un)\"" root.out &&
	jq -e .broker_version root.out &&
	jq -e .rank root.out &&
	jq -e .size root.out
'

test_expect_success 'unknown endpoint returns 404' '
	test_expect_code 22 $CURL -f \
	    http://localhost/api/v1/nonexistent 2>notfound.err &&
	grep 404 notfound.err
'

# Start a separate server with a 1s idle timeout, confirm it responds, then
# confirm it has exited after a few idle seconds (nothing listening -> curl
# fails to connect). Use the rundir (not $(pwd)) for the socket: the deep
# distcheck build path would exceed the AF_UNIX sun_path length limit.
test_expect_success 'idle-timeout exits the server after inactivity' '
	idlesock="$(flux getattr rundir)/idle.sock" &&
	flux exec -r 0 --bg flux rest-server \
	    --socket "$idlesock" --idle-timeout=1s &&
	tries=50 &&
	while test $tries -gt 0; do
		curl ${CURL_TIMEOUT_ARGS} -sf --unix-socket "$idlesock" \
		    http://localhost/api/v1/health >/dev/null 2>&1 && break
		tries=$((tries-1))
		sleep 0.1
	done &&
	test $tries -gt 0 &&
	sleep 3 &&
	test_expect_code 7 curl ${CURL_TIMEOUT_ARGS} -sf \
	    --unix-socket "$idlesock" http://localhost/api/v1/health
'

test_expect_success 'idle-timeout rejects an invalid duration' '
	test_must_fail flux rest-server --idle-timeout=bogus 2>fsd.err &&
	grep -i "duration" fsd.err
'

test_done
