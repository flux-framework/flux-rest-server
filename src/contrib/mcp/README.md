# flux-rest-server MCP server

A minimal [FastMCP](https://github.com/jlowin/fastmcp) server exposing
flux-rest-server's job submit/status/cancel endpoints as MCP tools:
`submit_job`, `get_job_info`, `cancel_job`.

This is a separate consumer of the REST API to demonstrate an example.

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
| `FLUX_REST_TOKEN` | (unset) | A JWT, sent as the "x-token" header |

If none of these are set, no auth header is sent at all -- appropriate
for a direct, already-trusted connection. Set FLUX_REST_USER/PASSWORD to
authenticate as a real end user through the full nginx + polkit + systemd
system-mode chain. FLUX_REST_TOKEN is an alternative, for a JWT-based
deployment instead.

## A note on trust assumptions

flux-rest-server never validates credentials itself, regardless of the
mechanism in front of it (Basic Auth, a trusted header, or a JWT). It
assumes whatever sits upstream has already established the caller's
identity by the time a request arrives. FLUX_REST_TOKEN here follows
the same assumption: the token is attached to every request, but
nothing in this server or this example validates it. Checking a JWT's
signature before a request reaches flux-rest-server is a separate,
not-yet-built piece of infrastructure.

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

## Testing thoroughly against a live server, as a real user

**1. Boot a real system instance:**
```bash
podman machine init --rootful
podman machine start
./src/test/docker/docker-run-system.sh --interactive
```
This drops you into a shell as yourself, a real guest user on a system
instance with working guest job submission.

**2. Install the MCP packages and run `example_client.py` as yourself:**
```bash
pip3 install --break-system-packages mcp fastmcp httpx

FLUX_REST_URL=http://localhost:8080/api/v1 \
FLUX_REST_USER=$(whoami) \
FLUX_REST_PASSWORD=testpw \
python3 src/contrib/mcp/example_client.py
```

**3. Example output.** The system instance is owned by root, but
systemd starts each user's own flux-rest-server process as that user,
not root, which is why the job below runs under your own identity:
```
=== submit_job ===
{'id': 'fDjwu2md'}

=== get_job_info ===
{'t_depend': 1790874978.519453, ..., 'name': 'sleep', 'cwd': '/home/alice',
 'ntasks': 1, 'ncores': 1, 'nnodes': 1, 'state': 'RUN', 'username': 'alice',
 'userid': 1000, ...}

=== cancel_job ===
{'id': 'fDjwu2md', 'status': 'cancel requested'}

=== get_job_info (after cancel) ===
state=INACTIVE result=CANCELED
```
