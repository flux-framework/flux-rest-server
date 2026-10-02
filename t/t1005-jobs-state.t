#!/bin/sh

test_description='Test GET /api/v1/jobs/<id>'

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

test_expect_success 'a running job returns 200 with id and state, no result yet' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	$CURL -s -o running.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/$jobid >running.code &&
	test "$(cat running.code)" = "200" &&
	test "$(jq -r .id running.out)" = "$jobid" &&
	test "$(jq -r .state running.out)" = "RUN" &&
	! jq -e ".result" running.out >/dev/null &&
	flux cancel $jobid
'

test_expect_success 'a completed job includes result and other fields' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": [\"true\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s http://localhost/api/v1/jobs/$jobid >done.out &&
	test "$(jq -r .state done.out)" = "INACTIVE" &&
	test "$(jq -r .result done.out)" = "COMPLETED" &&
	test "$(jq -r .name done.out)" = "true" &&
	jq -e ".ntasks" done.out >/dev/null
'

test_expect_success 'a failed job reports result=FAILED and a returncode' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": [\"false\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s http://localhost/api/v1/jobs/$jobid >failed.out &&
	test "$(jq -r .result failed.out)" = "FAILED" &&
	test "$(jq -r .returncode failed.out)" = "1"
'

test_expect_success '"id" is f58plain (not a raw int), and "jobid" is not leaked' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": [\"true\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s http://localhost/api/v1/jobs/$jobid >idcheck.out &&
	test "$(jq -r .id idcheck.out)" = "$jobid" &&
	echo "$jobid" | grep -qE "^f[A-Za-z0-9]+$" &&
	! jq -e ".jobid" idcheck.out >/dev/null
'

# Checks that a percent-encoded API prefix (e.g. /api%2Fv1/...) is
# rejected, not silently treated as a match for /api/v1/.
test_expect_success 'a double-encoded API prefix is rejected, not routed' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	$CURL -s -o encoded.out -w "%{http_code}" --path-as-is \
	    "http://localhost/api%2Fv1/jobs/$jobid" >encoded.code &&
	test "$(cat encoded.code)" = "404" &&
	flux cancel $jobid
'

test_expect_success 'a fancy (non-ASCII) F58 job id is accepted as input' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	fancy=$(flux job id --to=f58 $jobid) &&
	$CURL -s -o fancy.out -w "%{http_code}" \
	    "http://localhost/api/v1/jobs/$fancy" >fancy.code &&
	test "$(cat fancy.code)" = "200" &&
	test "$(jq -r .id fancy.out)" = "$jobid"
'

test_expect_success 'canceled job for attrs tests' '
	jobid=$($CURL -s -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sleep\", \"300\"]}" | jq -r .id) &&
	flux job wait-event -t 10 $jobid start >/dev/null &&
	flux cancel $jobid &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	echo $jobid >canceled.id
'

test_expect_success 'attrs returns only the requested fields, plus id' '
	jobid=$(cat canceled.id) &&
	$CURL -s "http://localhost/api/v1/jobs/$jobid?attrs=state,result" \
	    >subset.out &&
	test "$(jq -c "keys" subset.out)" = "[\"id\",\"result\",\"state\"]" &&
	test "$(jq -r .id subset.out)" = "$jobid" &&
	test "$(jq -r .result subset.out)" = "CANCELED"
'

test_expect_success 'any exception attr returns the full exception object' '
	jobid=$(cat canceled.id) &&
	$CURL -s "http://localhost/api/v1/jobs/$jobid?attrs=exception_type" \
	    >exc.out &&
	test "$(jq -c "keys" exc.out)" = "[\"exception\",\"id\"]" &&
	test "$(jq -r .exception.occurred exc.out)" = "true" &&
	test "$(jq -r .exception.type exc.out)" = "cancel"
'

test_expect_success 'an unknown attr returns 400, not 503' '
	jobid=$(cat canceled.id) &&
	$CURL -s -o badattr.out -w "%{http_code}" \
	    "http://localhost/api/v1/jobs/$jobid?attrs=state,bogus" \
	    >badattr.code &&
	test "$(cat badattr.code)" = "400" &&
	jq -r .error badattr.out | grep "bogus"
'

test_expect_success 'ranks and nodelist are omitted for a pending job' '
	jobid=$(flux submit --urgency=0 true) &&
	$CURL -s "http://localhost/api/v1/jobs/$jobid?attrs=ranks,nodelist" \
	    >pending.out &&
	test "$(jq -c "keys" pending.out)" = "[\"id\"]" &&
	flux cancel $jobid
'

test_expect_success 'attrs returns duration and expiration for a time-limited job' '
	jobid=$(flux submit -t 60s true) &&
	flux job wait-event -t 10 $jobid clean >/dev/null &&
	$CURL -s "http://localhost/api/v1/jobs/$jobid?attrs=duration,expiration" \
	    >limit.out &&
	test "$(jq -c "keys" limit.out)" = "[\"duration\",\"expiration\",\"id\"]" &&
	test "$(jq ".duration == 60" limit.out)" = "true"
'

test_expect_success 'nonexistent job returns 404' '
	$CURL -s -o missing.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/999999999999 >missing.code &&
	test "$(cat missing.code)" = "404"
'

test_expect_success 'malformed job id returns 400' '
	$CURL -s -o badid.out -w "%{http_code}" \
	    http://localhost/api/v1/jobs/not-a-real-id >badid.code &&
	test "$(cat badid.code)" = "400"
'

test_done
