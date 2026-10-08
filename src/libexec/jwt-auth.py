#!/usr/bin/env python3
##############################################################
# Copyright 2026 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
##############################################################

"""
JWT validation service for nginx auth_request directive.

Usage:
    # Run directly with uv (no virtual environment needed)
    uv run nginx-auth.py --jwks-url https://example.com/.well-known/jwks.json

    # Specify host and port
    uv run nginx-auth.py --jwks-url https://example.com/.well-known/jwks.json --host 0.0.0.0 --port 9000

    # Using environment variable for JWKS URL
    JWKS_URL=https://example.com/.well-known/jwks.json uv run nginx-auth.py

The script validates JWTs using the provided JWKS endpoint and returns the user
from the JWT's 'sub' claim via the X-User header for nginx to forward upstream.
"""
# /// script
# dependencies = [
#   "fastapi==0.115.0",
#   "uvicorn==0.32.0",
#   "pyjwt[crypto]==2.9.0",
#   "httpx==0.27.2",
# ]
# ///

import argparse
import sys

import httpx
import jwt
from fastapi import FastAPI, Header, Response
from jwt import PyJWKClient


def create_app(jwks_url: str, cache_ttl: int = 300) -> FastAPI:
    """Create FastAPI app with JWT validation.

    Args:
        jwks_url: URL to fetch JWKS from
        cache_ttl: How long to cache JWKS keys in seconds (default: 300)
    """
    app = FastAPI()
    jwks_client = PyJWKClient(jwks_url, cache_keys=True, lifespan=cache_ttl)

    @app.get("/validate")
    async def validate(authorization: str = Header(None)):
        if not authorization or not authorization.startswith("Bearer "):
            return Response(status_code=401)

        token = authorization.replace("Bearer ", "")
        try:
            signing_key = jwks_client.get_signing_key_from_jwt(token)
            payload = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256", "ES256"],
                options={"verify_aud": False},
            )

            user = payload.get("sub")
            if not user:
                return Response(status_code=401)

            return Response(status_code=200, headers={"X-User": user})
        except jwt.InvalidTokenError:
            return Response(status_code=401)
        except Exception:
            return Response(status_code=401)

    @app.get("/healthz")
    async def health():
        return {"status": "ok"}

    return app


def main():
    parser = argparse.ArgumentParser(
        description="JWT validation service for nginx auth_request"
    )
    parser.add_argument(
        "--jwks-url",
        required=True,
        help="JWKS URL for JWT validation (e.g., https://example.com/.well-known/jwks.json)",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to")
    parser.add_argument("--port", type=int, default=8080, help="Port to bind to")
    parser.add_argument(
        "--cache-ttl",
        type=int,
        default=300,
        help="JWKS cache TTL in seconds (default: 300)",
    )

    args = parser.parse_args()

    try:
        response = httpx.get(args.jwks_url, timeout=5)
        response.raise_for_status()
    except Exception as e:
        print(f"Error: Could not fetch JWKS from {args.jwks_url}: {e}", file=sys.stderr)
        sys.exit(1)

    app = create_app(args.jwks_url, cache_ttl=args.cache_ttl)

    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
