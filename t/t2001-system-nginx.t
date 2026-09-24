#!/bin/sh

test_description='Test the nginx front end against a Flux system instance

Drives real HTTP through the nginx config shipped in
nginx/flux-rest-server-insecure.conf.example -- the same file the README tells
sites to start from -- so the example is parsed by nginx and exercised
end to end: Basic auth, the auth_request to the _ensure helper, and proxy_pass
to the authenticated user'\''s socket.

t2000 covers the same machinery over unix sockets, without nginx.  This file
touches only the accounts in $SYSTEM_TEST_USER_A/_B, and t2000 touches only
$USER, so the two share no systemd units and may run in parallel.

Requires the container built by src/test/docker/docker-run-system.sh.  Run with
`make check-system`; these tests are deliberately absent from TESTS.
'

. $(dirname $0)/sharness.sh
. ${SHARNESS_TEST_SRCDIR}/../src/test/system-env.sh

# error() rather than skip_all: see the comment in t2000-system-activation.t.
test -S /run/flux/local ||
	error "no Flux system instance at /run/flux/local"
systemctl is-active --quiet nginx ||
	error "nginx is not running; see src/test/system_run.sh"
test -f /etc/nginx/flux.htpasswd ||
	error "/etc/nginx/flux.htpasswd is missing; see src/test/system_run.sh"

URL="http://localhost:${SYSTEM_TEST_PORT}"
USER_A=${SYSTEM_TEST_USER_A}
USER_B=${SYSTEM_TEST_USER_B}
PW=${SYSTEM_TEST_PASSWORD}

# An ordinary HTTP client.  Nothing here runs as the web-server user: that is
# the point -- nginx is the only thing that touches the per-user sockets.
CURL="curl ${CURL_TIMEOUT_ARGS}"

# HTTP status code only.
code() {
	$CURL -s -o /dev/null -w "%{http_code}" "$@"
}

test_expect_success 'request with no credentials is rejected' '
	test "$(code ${URL}/api/v1/)" = "401"
'

test_expect_success 'request with a wrong password is rejected' '
	test "$(code -u ${USER_A}:wrongpassword ${URL}/api/v1/)" = "401"
'

test_expect_success 'request for an unknown account is rejected' '
	test "$(code -u nosuchuser:${PW} ${URL}/api/v1/)" = "401"
'

# The whole chain in one request: Basic auth -> auth_request -> _ensure ->
# polkit -> systemctl start -> socket activation -> setuid -> system instance.
test_expect_success 'authenticated request reaches the API' '
	test "$(code -u ${USER_A}:${PW} ${URL}/api/v1/health)" = "200"
'

test_expect_success 'GET / is served as the authenticated user' '
	$CURL -s -u ${USER_A}:${PW} ${URL}/api/v1/ >a.out &&
	jq -e ".user == \"${USER_A}\"" a.out &&
	jq -e ".rank == 0" a.out
'

test_expect_success 'nginx activated that user service, not another' '
	systemctl is-active --quiet flux-rest-server@${USER_A}.service
'

# The privilege separation claim, checked directly: the process nginx proxied
# to runs as that user, not as nginx and not as root.
test_expect_success 'the per-user service runs as that user' '
	pid=$(systemctl show -p MainPID --value flux-rest-server@${USER_A}.service) &&
	test -n "$pid" && test "$pid" != "0" &&
	test "$(ps -o user= -p $pid | tr -d " ")" = "${USER_A}"
'

test_expect_success 'a second user gets a separate service as themselves' '
	$CURL -s -u ${USER_B}:${PW} ${URL}/api/v1/ >b.out &&
	jq -e ".user == \"${USER_B}\"" b.out &&
	pid=$(systemctl show -p MainPID --value flux-rest-server@${USER_B}.service) &&
	test "$(ps -o user= -p $pid | tr -d " ")" = "${USER_B}"
'

test_expect_success 'the two users are served by different processes' '
	pid_a=$(systemctl show -p MainPID --value flux-rest-server@${USER_A}.service) &&
	pid_b=$(systemctl show -p MainPID --value flux-rest-server@${USER_B}.service) &&
	test "$pid_a" != "$pid_b"
'

# The config rejects anything that is not a plain username *before* it is
# interpolated into /run/flux-rest-server/$remote_user.sock.  This account
# authenticates successfully, so only that guard can produce the 403.
test_expect_success 'a username the config disallows is refused after auth' '
	test "$(code -u ${SYSTEM_TEST_BADUSER}:${PW} ${URL}/api/v1/)" = "403"
'

test_expect_success 'submit a job over HTTP' '
	$CURL -s -u ${USER_A}:${PW} -X POST ${URL}/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" >submit.out &&
	jq -e ".id | type == \"string\"" submit.out &&
	jq -er ".id" submit.out >jobid
'

# If any of the chain leaked privilege -- nginx'\''s uid, or the instance
# owner'\''s -- it would show up here as the wrong owner.
test_expect_success 'the job is owned by the authenticated user' '
	id=$(cat jobid) &&
	test "$(flux jobs -A -no {userid} $id)" = "$(id -u ${USER_A})"
'

test_expect_success 'a job submitted by the other user is owned by them' '
	$CURL -s -u ${USER_B}:${PW} -X POST ${URL}/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" >submitb.out &&
	id=$(jq -er ".id" submitb.out) &&
	test "$(flux jobs -A -no {userid} $id)" = "$(id -u ${USER_B})"
'

test_expect_success 'unknown route returns 404 through nginx' '
	test "$(code -u ${USER_A}:${PW} ${URL}/api/v1/nosuchroute)" = "404"
'

# The _ensure location is marked "internal", so it is reachable by
# auth_request but not from outside.  Were it not, any authenticated client
# could start a service for any user it named.
test_expect_success 'the _ensure location is not reachable from outside' '
	test "$(code -u ${USER_A}:${PW} ${URL}/_ensure)" = "404"
'

test_done
