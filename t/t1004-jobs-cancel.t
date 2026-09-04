#!/bin/sh

test_description='Test DELETE /api/v1/jobs/<id>'

. $(dirname $0)/sharness.sh

test_under_flux 1

REST_SOCKET="$(flux getattr rundir)/rest"
CURL="curl --unix-socket ${REST_SOCKET}"

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

test_expect_success 'cancel a running job returns 202, and the job is actually canceled' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	$CURL -s -o cancel.out -w "%{http_code}" -X DELETE \
	    "http://localhost/api/v1/jobs/$jobid?reason=test+cancel" >cancel.code &&
	test "$(cat cancel.code)" = "202" &&
	jq -e ".id" cancel.out &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	flux job eventlog $jobid | grep -q "test cancel"
'

test_expect_success 'cancel without a reason still works' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	$CURL -s -o cancel2.out -w "%{http_code}" -X DELETE \
	    "http://localhost/api/v1/jobs/$jobid" >cancel2.code &&
	test "$(cat cancel2.code)" = "202"
'

test_expect_success 'canceling an already-inactive job returns 409, not 404' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": [\"true\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s -o already.out -w "%{http_code}" -X DELETE \
	    "http://localhost/api/v1/jobs/$jobid" >already.code &&
	test "$(cat already.code)" = "409"
'

test_expect_success 'canceling a nonexistent job returns 404, not 409' '
	$CURL -s -o missing.out -w "%{http_code}" -X DELETE \
	    http://localhost/api/v1/jobs/999999999999 >missing.code &&
	test "$(cat missing.code)" = "404"
'

test_expect_success 'malformed job id returns 400' '
	$CURL -s -o badid.out -w "%{http_code}" -X DELETE \
	    http://localhost/api/v1/jobs/not-a-real-id >badid.code &&
	test "$(cat badid.code)" = "400"
'

test_expect_success 'job ids are returned in f58plain (ASCII) form' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": [\"true\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	echo "$jobid" | grep -qE "^f[A-Za-z0-9]+$"
'

test_expect_success 'cancel accepts a decimal-form job id' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	decimal=$(flux job id --to=dec $jobid) &&
	$CURL -s -o decform.out -w "%{http_code}" -X DELETE \
	    "http://localhost/api/v1/jobs/$decimal" >decform.code &&
	test "$(cat decform.code)" = "202"
'

test_expect_success 'cancel accepts the fancy (non-ASCII) F58 job id form' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	fancy=$(flux job id --to=f58 $jobid) &&
	$CURL -s -o fancyform.out -w "%{http_code}" -X DELETE \
	    "http://localhost/api/v1/jobs/$fancy" >fancyform.code &&
	test "$(cat fancyform.code)" = "202"
'

test_expect_success 'unrelated existing routes still work' '
	$CURL -s -o submit.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" >submit.code &&
	test "$(cat submit.code)" = "201" &&
	$CURL -s -o health.out -w "%{http_code}" \
	    http://localhost/api/v1/health >health.code &&
	test "$(cat health.code)" = "200"
'

test_done
