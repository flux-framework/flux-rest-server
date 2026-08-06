#!/usr/bin/env python3
"""Example client for flux_rest_mcp.py -- submit, check, then cancel a job.

Also generates a mock JWT and sends it via FLUX_REST_TOKEN, to illustrate
that path even though nothing in this server validates it.

Run this against a live flux-rest-server (set FLUX_REST_URL if it's not
at the default http://localhost:8080/api/v1):

    python3 example_client.py

Requires the `mcp` client package, plus pyjwt/cryptography for the mock
token: pip install mcp pyjwt cryptography
"""

import asyncio
import json
import os
import time

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

_HERE = os.path.dirname(os.path.abspath(__file__))


def _generate_mock_jwt() -> str:
    """A well-formed, self-signed JWT, shaped like a real one.

    Signed with a key generated just for this run. Nothing checks it
    against that key, since flux-rest-server never validates anything
    itself. This just shows that FLUX_REST_TOKEN reaches the "x-token"
    header correctly.
    """
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    now = int(time.time())
    claims = {"sub": "alice", "iat": now, "nbf": now, "exp": now + 3600}
    return jwt.encode(claims, private_pem, algorithm="RS256", headers={"kid": "mock"})


MOCK_TOKEN = _generate_mock_jwt()

# StdioServerParameters only inherits a safe, filtered subset of the
# parent environment by default (PATH, HOME, etc.) -- FLUX_REST_URL and
# friends must be passed explicitly, or the server falls back to its
# own default (http://localhost:8080/api/v1).
SERVER_PARAMS = StdioServerParameters(
    command="python3",
    args=[os.path.join(_HERE, "flux_rest_mcp.py")],
    env={
        **{
            k: v
            for k, v in os.environ.items()
            if k in ("FLUX_REST_URL", "FLUX_REST_USER", "FLUX_REST_PASSWORD")
        },
        "FLUX_REST_TOKEN": MOCK_TOKEN,
    },
)


async def main():
    print("=== mock JWT (sent as the x-token header below) ===")
    print(MOCK_TOKEN)
    print()

    async with (
        stdio_client(SERVER_PARAMS) as (read, write),
        ClientSession(read, write) as session,
    ):
        await session.initialize()

        print("=== submit_job ===")
        result = await session.call_tool(
            "submit_job",
            arguments={"command": ["sleep", "60"], "num_tasks": 1},
        )
        submitted = json.loads(result.content[0].text)
        print(submitted)
        if "error" in submitted:
            return
        jobid = submitted["id"]

        print("\n=== get_job_info ===")
        result = await session.call_tool("get_job_info", arguments={"jobid": jobid})
        info = json.loads(result.content[0].text)
        print(info)

        print("\n=== cancel_job ===")
        result = await session.call_tool(
            "cancel_job",
            arguments={"jobid": jobid, "reason": "example client done"},
        )
        print(json.loads(result.content[0].text))

        print("\n=== get_job_info (after cancel) ===")
        result = await session.call_tool("get_job_info", arguments={"jobid": jobid})
        info = json.loads(result.content[0].text)
        print(f"state={info.get('state')} result={info.get('result')}")


if __name__ == "__main__":
    asyncio.run(main())
