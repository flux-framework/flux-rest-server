#!/bin/sh

test_description='Test socket activation against a Flux system instance

This is the README "System mode" smoke test, executed: the _ensure helper, the
polkit rule, systemd socket activation, the per-user setuid, and guest access
to the *system* instance.  None of that can be reached from `make check`, which
runs the server against a session instance over a self-created 0600 socket.

Requires the container built by src/test/docker/docker-run-system.sh.  Run with
`make check-system`; these tests are deliberately absent from TESTS.
'

. $(dirname $0)/sharness.sh
. ${SHARNESS_TEST_SRCDIR}/../src/test/system-env.sh

# Deliberately error() rather than skip_all: these tests are opt-in, so if you
# asked for them and the environment is wrong, that is a failure, not a skip.
# A silently-skipping system test suite reports green when the container is
# broken -- the one failure mode this whole harness exists to avoid.
test -S /run/flux/local ||
	error "no Flux system instance at /run/flux/local"
test "$(flux getattr security.owner)" != "$(id -u)" ||
	error "the system instance is owned by $(id -un); these tests run as a guest"
test -S ${SYSTEM_TEST_SOCKDIR}/ensure.sock ||
	error "flux-rest-server-ensure.socket is not listening; is it installed and enabled?"

# Derive the account name rather than trusting $USER: `podman exec -u` sets the
# uid but not the environment, so $USER is empty in the container.
TEST_USER=$(id -un)
WEB_USER=${SYSTEM_TEST_WEB_USER}
ENSURE_SOCK=${SYSTEM_TEST_SOCKDIR}/ensure.sock
USER_SOCK=${SYSTEM_TEST_SOCKDIR}/${TEST_USER}.sock

# Every request the web server makes, it makes as $WEB_USER.  Connecting as
# ourselves or as root is intentionally refused, so there is no shortcut here.
web_curl() {
	sudo -u ${WEB_USER} curl ${CURL_TIMEOUT_ARGS} "$@"
}

# GET on the _ensure socket, as nginx's auth_request does.
ensure() {
	web_curl -s -o /dev/null -w "%{http_code}" \
	    --unix-socket ${ENSURE_SOCK} \
	    -H "X-Remote-User: $1" http://localhost/
}

test_expect_success 'flux-rest-server-ensure.socket is active' '
	systemctl is-active --quiet flux-rest-server-ensure.socket
'

# Stop the service as well as the socket.  systemd refuses to start a .socket
# whose service is still running ("Socket service already active, refusing"),
# so leaving it up makes every activation below fail.  That happens whenever
# something has already used the API on this account -- an interactive session,
# or a previous run of this file.
test_expect_success 'per-user socket is not started until asked for' '
	sudo systemctl stop flux-rest-server@${TEST_USER}.socket \
	                   flux-rest-server@${TEST_USER}.service 2>/dev/null || true &&
	test_must_fail systemctl is-active --quiet flux-rest-server@${TEST_USER}.socket
'

# The helper runs as nginx and calls `systemctl start` -- which only succeeds
# if the polkit rule authorized it.  A 200 here means the whole
# nginx -> helper -> polkit -> systemd chain worked.
test_expect_success '_ensure helper starts the per-user socket' '
	test "$(ensure ${TEST_USER})" = "200" &&
	systemctl is-active --quiet flux-rest-server@${TEST_USER}.socket
'

test_expect_success '_ensure helper is idempotent' '
	test "$(ensure ${TEST_USER})" = "200"
'

test_expect_success '_ensure helper rejects a malformed username' '
	test "$(ensure "../../etc/passwd")" = "403"
'

test_expect_success '_ensure helper rejects an empty username' '
	web_curl -s -o /dev/null -w "%{http_code}" \
	    --unix-socket ${ENSURE_SOCK} http://localhost/ >empty.code &&
	test "$(cat empty.code)" = "401"
'

test_expect_success 'socket directory is search-only (0711)' '
	test "$(stat -c %a ${SYSTEM_TEST_SOCKDIR})" = "711"
'

test_expect_success 'per-user socket is 0660 root:web-user' '
	test "$(stat -c %a ${USER_SOCK})" = "660" &&
	test "$(stat -c %U:%G ${USER_SOCK})" = "root:${WEB_USER}"
'

# The first connection is what activates the service; before this the .socket
# unit exists but nothing is running.
test_expect_success 'first connection activates the per-user service' '
	test "$(web_curl -s -o /dev/null -w "%{http_code}" \
	    --unix-socket ${USER_SOCK} http://localhost/api/v1/health)" = "200" &&
	systemctl is-active --quiet flux-rest-server@${TEST_USER}.service
'

test_expect_success 'service runs as the requested user, not root' '
	pid=$(systemctl show -p MainPID --value flux-rest-server@${TEST_USER}.service) &&
	test -n "$pid" && test "$pid" != "0" &&
	test "$(ps -o user= -p $pid | tr -d " ")" = "${TEST_USER}"
'

# This is the payoff: the server called flux.Flux() with no FLUX_URI set and
# reached the system instance as the connecting user.
test_expect_success 'GET / reports the system instance as the right user' '
	web_curl -s --unix-socket ${USER_SOCK} http://localhost/api/v1/ >root.out &&
	jq -e ".user == \"${TEST_USER}\"" root.out &&
	jq -e ".rank == 0" root.out &&
	jq -e ".size == 1" root.out
'

# A session instance would be owned by us.  The system instance is owned by
# "flux", and we reach it with the guest role -- which is the arrangement the
# whole design depends on.
test_expect_success 'the instance reached is the system instance' '
	test "$(flux getattr security.owner)" != "$(id -u)" &&
	test "$(flux getattr local-uri)" = "local:///run/flux/local"
'

# The socket is 0660 root:nginx, so the mode alone stops us.  Test as root,
# which bypasses the file mode, to reach the application-level SO_PEERCRED
# check in _Server.verify_request -- the path --allow-user actually guards.
test_expect_success 'connection from root is refused by SO_PEERCRED' '
	sudo curl ${CURL_TIMEOUT_ARGS} -s -w "%{http_code}\n" \
	    --unix-socket ${USER_SOCK} http://localhost/api/v1/health \
	    >rootconn.out &&
	test "$(tail -1 rootconn.out)" = "403" &&
	head -1 rootconn.out >rootconn.body &&
	jq -e ".error == \"forbidden\"" rootconn.body
'

# We own the service but not the socket, whose 0660 root:nginx mode stops us
# before SO_PEERCRED ever runs.  curl exits 7 (couldn'\''t connect); assert that
# exact code so a timeout (28) can never pass for the failure under test.
test_expect_success 'the owning user cannot reach its own socket' '
	test_expect_code 7 curl ${CURL_TIMEOUT_ARGS} -s -o /dev/null \
	    --unix-socket ${USER_SOCK} http://localhost/api/v1/health
'

test_expect_success 'submit a job as a guest of the system instance' '
	web_curl -s --unix-socket ${USER_SOCK} \
	    -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" >submit.out &&
	jq -e ".id | type == \"string\"" submit.out &&
	jq -er ".id" submit.out >jobid
'

# Ownership is the whole point of the per-user service: the job must belong to
# us, not to the web server and not to the instance owner.
test_expect_success 'the job is owned by the submitting user' '
	id=$(cat jobid) &&
	test "$(flux jobs -no {userid} $id)" = "$(id -u)"
'

# Runs through the IMP under the system instance -- a real setuid job launch.
test_expect_success 'the job runs to completion' '
	id=$(cat jobid) &&
	flux job wait-event -t 60 $id clean &&
	test "$(flux jobs -no {result} $id)" = "COMPLETED"
'

test_expect_success 'cancel a job through the API' '
	web_curl -s --unix-socket ${USER_SOCK} \
	    -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" >cancel.out &&
	id=$(jq -er ".id" cancel.out) &&
	test "$(web_curl -s -o /dev/null -w "%{http_code}" \
	    --unix-socket ${USER_SOCK} \
	    -X DELETE http://localhost/api/v1/jobs/$id)" = "202" &&
	flux job wait-event -t 60 $id clean &&
	test "$(flux jobs -no {result} $id)" = "CANCELED"
'

# --idle-timeout reaps the per-user server; the .socket stays up and the next
# request must bring the service back.  Stopping it by hand is the same
# transition, without waiting 5 minutes for it.
test_expect_success 'service re-activates after it exits' '
	sudo systemctl stop flux-rest-server@${TEST_USER}.service &&
	test_must_fail systemctl is-active --quiet flux-rest-server@${TEST_USER}.service &&
	test "$(web_curl -s -o /dev/null -w "%{http_code}" \
	    --unix-socket ${USER_SOCK} http://localhost/api/v1/health)" = "200" &&
	systemctl is-active --quiet flux-rest-server@${TEST_USER}.service
'

test_done
