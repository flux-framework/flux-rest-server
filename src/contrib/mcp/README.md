# flux-rest-server MCP server

A minimal [FastMCP](https://github.com/jlowin/fastmcp) server exposing
flux-rest-server's job submit/status/cancel endpoints as MCP tools:
`submit_job`, `get_job_info`, `cancel_job`.

This is a separate consumer of the REST API, not part of flux-rest-server
itself -- it has real third-party dependencies (fastmcp, httpx), unlike
the stdlib-only server. It is not wired into the autotools build; run it
directly with Python.

## Install

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Configure

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `FLUX_REST_URL` | `http://localhost:8080/api/v1` | Base URL of flux-rest-server |
| `FLUX_REST_USER` | (unset) | Basic Auth username |
| `FLUX_REST_PASSWORD` | (unset) | Basic Auth password |

If `FLUX_REST_USER` is unset, no `Authorization` header is sent at all --
appropriate for a direct, already-trusted connection. Set both to
authenticate as a real end user through the full nginx + polkit + systemd
system-mode chain.

## Run

```bash
python3 flux_rest_mcp.py
```

## Quick test

`example_client.py` exercises all three tools end to end (submit, check
info, cancel) through the real MCP protocol -- a good first smoke test
before wiring this up to a real agent:

```bash
python3 example_client.py
```

## Testing thoroughly against a live server, as a real user (alice)

This exercises the full identity chain -- nginx Basic Auth -> polkit ->
systemd socket activation -> alice's own per-user flux-rest-server
process -- not just a direct, already-trusted connection.

**1. Have the system-mode Docker container running** (see
`src/test/docker/bookworm/system-mode/README.md`), with alice's password
already set via `htpasswd`.

**2. Point the MCP server at it:**
```bash
export FLUX_REST_URL="http://localhost:8080/api/v1"
export FLUX_REST_USER="alice"
export FLUX_REST_PASSWORD="<alice's real password>"
```

**3. Exercise all three tools directly, as a smoke test before wiring up
a real MCP client:**
```bash
python3 - << 'EOF'
import asyncio
from flux_rest_mcp import submit_job, get_job_info, cancel_job

async def main():
    # matches "flux submit -N1 -n2 sleep 10"
    result = await submit_job(
        command=["sleep", "10"], num_nodes=1, num_tasks=2, name="alice-mcp-test"
    )
    print("submit:", result)
    jobid = result["id"]

    info = await get_job_info(jobid=jobid)
    print("state (should be RUN or SCHED):", info["state"])

    # let it run a couple seconds, then cancel it before it finishes
    await asyncio.sleep(2)
    cancel_result = await cancel_job(jobid=jobid, reason="MCP smoke test")
    print("cancel:", cancel_result)

    await asyncio.sleep(1)
    final = await get_job_info(jobid=jobid)
    print("final state (should be INACTIVE/CANCELED):", final["state"], final.get("result"))

asyncio.run(main())
EOF
```

**4. Confirm identity actually resolved to alice, not root/www-data** --
this is the part that specifically proves the tools went through the
real system-mode chain, not a shortcut:
```bash
docker exec -it -u alice flux-rest-server-test flux jobs -a
```
The job submitted above should show up here, owned by alice.

**5. Error cases worth confirming explicitly, not just the happy path:**
```bash
python3 - << 'EOF'
import asyncio
from flux_rest_mcp import get_job_info, cancel_job

async def main():
    print("nonexistent job:", await get_job_info(jobid="999999999999"))
    print("malformed job id:", await get_job_info(jobid="not-a-real-id"))

asyncio.run(main())
EOF
```
Expect `{"error": "no such job: ...", "status_code": 404}` and
`{"error": "... is not a valid Flux jobid", "status_code": 400}`
respectively.

**6. Once satisfied with direct tool calls, wire this up to a real MCP
client** -- `example_client.py` (in this same directory) is a minimal
reference for exactly this, using the standard `mcp` client SDK. Adapt
it, or point Claude Desktop or another MCP-capable agent at
`python3 flux_rest_mcp.py` with the same environment variables set, and
confirm the same behavior end-to-end through an actual agent conversation.
