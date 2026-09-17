#!/bin/sh

test_description='Validate the OpenAPI specification (openapi.yaml)'

. $(dirname $0)/sharness.sh

SPEC="${SHARNESS_TEST_SRCDIR}/../spec/v1/openapi.yaml"
CHECK="${SHARNESS_TEST_SRCDIR}/../scripts/openapi-check.py"
SERVER="${SHARNESS_TEST_SRCDIR}/../src/cmd/flux-rest-server.py"

if ! flux python -c "import yaml, openapi_spec_validator" 2>/dev/null; then
	skip_all="openapi-spec-validator and PyYAML required for spec validation"
	test_done
fi

test_expect_success 'openapi.yaml exists' '
	test -f "$SPEC"
'

# Run under `flux python` so the checker can import the server module, which
# imports flux. No broker is required.
test_expect_success 'spec conforms and documents exactly the implemented routes' '
	flux python "$CHECK" "$SPEC" "$SERVER"
'

test_done
