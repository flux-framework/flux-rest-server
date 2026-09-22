#!/bin/sh

test_description='Test POST /api/v1/jobs (basic submit)'

. $(dirname $0)/sharness.sh

test_under_flux 1

REST_SOCKET="$(flux getattr rundir)/rest"
CURL="curl ${CURL_TIMEOUT_ARGS} --unix-socket ${REST_SOCKET}"

# Same helper as t1000-basic.t: start the server in the background, return
# only once it is responding to requests.
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
	export SHOULD_NOT_LEAK_INTO_JOBS=leaked_value &&
	start_server
'

test_expect_success 'job id is returned as a string, not a JSON number' '
	$CURL -s -o idtype.out -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": [\"true\"]}" &&
	jq -e ".id | type == \"string\"" idtype.out
'

test_expect_success 'job id is the ASCII F58 plain form (no fancy prefix)' '
	id=$(jq -er ".id" idtype.out) &&
	echo "$id" | grep -qx "f[1-9A-HJ-NP-Za-km-z]*"
'

test_expect_success 'cwd defaults to the submitting user home directory' '
	real_home=$(python3 -c "import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)") &&
	$CURL -s -o cwd.out -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"pwd\"]}" &&
	id=$(jq -r ".id" cwd.out) &&
	flux job attach $id >cwd.stdout &&
	test "$(cat cwd.stdout)" = "$real_home"
'

test_expect_success 'environment defaults to a small set, not the server env' '
	$CURL -s -o env1.out -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"env\"]}" &&
	id=$(jq -r ".id" env1.out) &&
	flux job attach $id >env1.stdout &&
	! grep -q SHOULD_NOT_LEAK_INTO_JOBS env1.stdout &&
	grep -q "^HOME=" env1.stdout &&
	grep -q "^PATH=/usr/local/bin:/usr/bin:/bin$" env1.stdout
'

test_expect_success 'explicit cwd/environment override the defaults' '
	$CURL -s -o override.out -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"sh\", \"-c\", \"pwd; echo CUSTOM=\$CUSTOM_VAR\"], \"cwd\": \"/tmp\", \"environment\": {\"CUSTOM_VAR\": \"myvalue\"}}" &&
	id=$(jq -r ".id" override.out) &&
	flux job attach $id >override.stdout &&
	grep -q "^/tmp$" override.stdout &&
	grep -q "CUSTOM=myvalue" override.stdout
'

test_expect_success 'basic submit returns 201, and the job actually runs' '
	$CURL -s -o submit.out -D submit.hdr -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"]}" >submit.code &&
	test "$(cat submit.code)" = "201" &&
	id=$(jq -er ".id" submit.out) &&
	flux job attach $id
'

test_expect_success 'the 201 Location header points at the created job' '
	grep -i "^Location:" submit.hdr >loc.out &&
	id=$(jq -er ".id" submit.out) &&
	grep -iq "^Location:[ ]*/api/v1/jobs/$id" submit.hdr
'

test_expect_success 'extra fields (num_tasks, name) are honored' '
	$CURL -s -o submit2.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"], \"num_tasks\": 2, \"name\": \"t1002test\"}" \
	    >submit2.code &&
	test "$(cat submit2.code)" = "201" &&
	id2=$(jq -r ".id" submit2.out) &&
	flux jobs -a --format="{name}" $id2 >name.out &&
	grep -q t1002test name.out
'

test_expect_success 'num_nodes is honored' '
	$CURL -s -o submit3.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"], \"num_nodes\": 1}" \
	    >submit3.code &&
	test "$(cat submit3.code)" = "201" &&
	id3=$(jq -r ".id" submit3.out) &&
	flux job attach $id3 &&
	flux jobs -a --format="{nnodes}" $id3 >nnodes.out &&
	grep -q "^1$" nnodes.out
'

test_expect_success 'unknown field returns 400 instead of being ignored' '
	$CURL -s -o unknownfield.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"], \"num_gpus\": 1}" >unknownfield.code &&
	test "$(cat unknownfield.code)" = "400"
'

test_expect_success 'malformed Content-Length returns 400, not a crash' '
	$CURL -s -o cl.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -H "Content-Length: not-a-number" \
	    -d "{\"command\": [\"true\"]}" >cl.code &&
	test "$(cat cl.code)" = "400"
'

test_expect_success 'negative Content-Length returns 400, not a hang' '
	$CURL -s -o cln.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -H "Content-Length: -1" \
	    -d "{\"command\": [\"true\"]}" >cln.code &&
	test "$(cat cln.code)" = "400"
'

test_expect_success 'malformed input returns 400' '
	$CURL -s -o r1.out -w "%{http_code}" -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{}" >r1.code &&
	test "$(cat r1.code)" = "400" &&
	$CURL -s -o r2.out -w "%{http_code}" -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "{\"command\": \"true\"}" >r2.code &&
	test "$(cat r2.code)" = "400" &&
	$CURL -s -o r3.out -w "%{http_code}" -X POST http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" -d "not json" >r3.code &&
	test "$(cat r3.code)" = "400"
'

# Regression guard: flux.job.submit() raises a plain OSError for both "flux
# unreachable" and "request rejected as invalid" (e.g. bad queue), and only
# errno distinguishes them. A bad queue name must surface as 400 (client
# error), not 503 ("flux unavailable") -- confirmed empirically while
# developing this endpoint.
test_expect_success 'invalid queue name returns 400, not 503' '
	$CURL -s -o badqueue.out -w "%{http_code}" -X POST \
	    http://localhost/api/v1/jobs \
	    -H "Content-Type: application/json" \
	    -d "{\"command\": [\"true\"], \"queue\": \"nonexistent-queue-xyz\"}" \
	    >badqueue.code &&
	test "$(cat badqueue.code)" = "400"
'

test_expect_success 'POST to an unknown path returns 404' '
	test_expect_code 22 $CURL -f -X POST \
	    http://localhost/api/v1/nonexistent 2>unknown.err &&
	grep 404 unknown.err
'

test_done
