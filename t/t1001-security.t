#!/bin/sh

test_description='Test connection access control: socket mode and SO_PEERCRED'

. $(dirname $0)/sharness.sh

test_under_flux 1

REST_SOCKET="$(flux getattr rundir)/rest"
CURL="curl ${CURL_TIMEOUT_ARGS} --unix-socket ${REST_SOCKET}"

# A user whose uid differs from the current one, for negative checks.
if test "$(id -u)" = "0"; then other_user=nobody; else other_user=root; fi
if id "$other_user" >/dev/null 2>&1 \
	&& test "$(id -u "$other_user")" != "$(id -u)"; then
	test_set_prereq OTHERUSER
fi

# Start the server (as the test user) in the background, returning only once
# it is responding.
start_server() {
	local tries=50

	flux exec -r 0 --bg flux rest-server || return 1

	while test $tries -gt 0; do
		$CURL -sf http://localhost/api/v1/health >/dev/null 2>&1 && return 0
		tries=$(($tries-1))
		sleep 0.1
	done
	return 1
}

test_expect_success 'start flux-rest-server' '
	start_server
'

test_expect_success 'default unix socket is owner-only (mode 0600)' '
	test "$(stat -c %a ${REST_SOCKET})" = "600"
'

test_expect_success 'owner can connect' '
	$CURL -sf http://localhost/api/v1/health >/dev/null
'

# A different uid must be refused.  When that uid is root -- which bypasses the
# 0600 file mode -- this specifically exercises the application-level
# SO_PEERCRED check rather than the socket file permissions.
test_expect_success SUDO,OTHERUSER 'connection from another uid gets 403' '
	$SUDO -u $other_user curl ${CURL_TIMEOUT_ARGS} -v -s \
	    -w "%{http_code}\n" \
	    --unix-socket ${REST_SOCKET} http://localhost/api/v1/health \
	    >forbidden.out &&
	test "$(tail -1 forbidden.out)" = "403" &&
	head -1 forbidden.out >forbidden.body &&
	jq -e ".error == \"forbidden\"" forbidden.body
'

# Refuse a configuration that would create an owner-only socket the named user
# could never reach; cross-user access requires socket activation.
test_expect_success OTHERUSER \
	'--allow-user with a self-created socket is refused' '
	test_must_fail flux rest-server --allow-user=$other_user 2>guard.err &&
	grep "socket activation" guard.err
'

test_done
