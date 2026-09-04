#!/usr/bin/python3
##############################################################
# Copyright 2026 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
##############################################################

"""Check the flux-rest-server OpenAPI specification.

Conformance to OpenAPI 3.1 is delegated to openapi-spec-validator. The only
project-specific check is that the spec documents exactly the endpoints the
server implements -- and that list is derived by introspecting the server's
own route tables rather than hardcoded here, so the spec and the code cannot
silently drift.

Usage: openapi-check.py OPENAPI-YAML [SERVER-SOURCE]

With only the spec, this validates OpenAPI 3.1 conformance and nothing else.
Conformance needs no Flux, so it suits a lightweight CI lint job:

    python3 scripts/openapi-check.py spec/v1/openapi.yaml

Given the server source too, it additionally checks route coverage. That
imports the server module (which imports flux), so run it under `flux
python` -- this is how the testsuite (t1003) drives it:

    flux python scripts/openapi-check.py spec/v1/openapi.yaml src/cmd/flux-rest-server.py
"""

import importlib.util
import sys

import yaml
from openapi_spec_validator import validate

# HTTP methods an OpenAPI path item may carry (OpenAPI 3.1 fixed fields).
HTTP_METHODS = {"get", "put", "post", "delete", "patch", "head", "options", "trace"}


def load_server(path):
    """Import the server module from its source path (its name has dashes and
    it is installed without a .py suffix, so a file-location import is used)."""
    spec = importlib.util.spec_from_file_location("flux_rest_server", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def implemented_operations(server):
    """The (path, method) pairs the server implements, with paths made
    relative to the API prefix so they line up with the spec's paths."""
    prefix = server._PREFIX
    ops = set()
    for method, table in (("get", server.ROUTES), ("post", server.POST_ROUTES)):
        for route in table:
            ops.add((route[len(prefix) :] or "/", method))

    # A bare /jobs/<id> route, if implemented (e.g. DELETE_JOB_ROUTE).
    for method, attr in (("delete", "DELETE_JOB_ROUTE"),):
        if getattr(server, attr, None) is not None:
            ops.add(("/jobs/{jobid}", method))
    return ops


def documented_operations(spec):
    """The (path, method) pairs the spec documents."""
    ops = set()
    for path, item in (spec.get("paths") or {}).items():
        for key in item:
            if key in HTTP_METHODS:
                ops.add((path, key))
    return ops


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit("usage: openapi-check.py OPENAPI-YAML [SERVER-SOURCE]")
    spec_path = args[0]
    server_path = args[1] if len(args) > 1 else None

    spec = yaml.safe_load(open(spec_path))
    validate(spec)

    # Route coverage is optional: it needs the server source (and therefore
    # flux), which a flux-free conformance-only lint will not have.
    if server_path is not None:
        implemented = implemented_operations(load_server(server_path))
        documented = documented_operations(spec)
        missing = implemented - documented
        extra = documented - implemented
        if missing:
            raise SystemExit(f"implemented but undocumented: {sorted(missing)}")
        if extra:
            raise SystemExit(f"documented but not implemented: {sorted(extra)}")

    print("ok")


if __name__ == "__main__":
    main()
