#!/usr/bin/env python3
"""MCP server exposing flux-rest-server's job submit/state/cancel endpoints.

Configuration (environment variables):
    FLUX_REST_URL       Base URL, e.g. http://localhost:8080/api/v1
                        (default: http://localhost:8080/api/v1)
    FLUX_REST_USER      Basic Auth username (optional)
    FLUX_REST_PASSWORD  Basic Auth password (optional; ignored if
                        FLUX_REST_USER is unset)

If FLUX_REST_USER is unset, no Authorization header is sent at all --
appropriate for a direct, already-trusted connection (e.g. local-mode
testing). Set both to authenticate as a real end user through the full
nginx + polkit + systemd system-mode chain.
"""

import os

import httpx
from fastmcp import FastMCP

FLUX_REST_URL = os.environ.get("FLUX_REST_URL", "http://localhost:8080/api/v1").rstrip("/")
FLUX_REST_USER = os.environ.get("FLUX_REST_USER")
FLUX_REST_PASSWORD = os.environ.get("FLUX_REST_PASSWORD")


def _auth():
    if FLUX_REST_USER:
        return (FLUX_REST_USER, FLUX_REST_PASSWORD or "")
    return None


async def _request(method, path, json_body=None, params=None):
    """Make a request against flux-rest-server, returning (status, dict).

    Never raises for a non-2xx response -- flux-rest-server's own error
    bodies (e.g. {"error": "..."}) are already the useful signal to return
    to the tool caller, not something to convert into an exception.
    """
    async with httpx.AsyncClient(auth=_auth(), timeout=30.0) as client:
        resp = await client.request(
            method, f"{FLUX_REST_URL}{path}", json=json_body, params=params
        )
    try:
        body = resp.json()
    except ValueError:
        body = {"error": resp.text or f"HTTP {resp.status_code}"}
    return resp.status_code, body


mcp = FastMCP("flux-rest-server")


@mcp.tool()
async def submit_job(
    command: list[str],
    num_nodes: int | None = None,
    num_tasks: int | None = None,
    cores_per_task: int | None = None,
    name: str | None = None,
) -> dict:
    """Submit a job to the Flux cluster.

    command: the program and arguments to run, e.g. ["sleep", "10"].
    Returns {"id": <jobid>} on success, or {"error": ...} on failure.
    """
    body = {"command": command}
    for key, value in (
        ("num_nodes", num_nodes),
        ("num_tasks", num_tasks),
        ("cores_per_task", cores_per_task),
        ("name", name),
    ):
        if value is not None:
            body[key] = value

    status, resp = await _request("POST", "/jobs", body)
    if status != 201:
        return {"error": resp.get("error", f"HTTP {status}"), "status_code": status}
    return resp


@mcp.tool()
async def get_job_info(jobid: str) -> dict:
    """Get a job's full status/info.

    Returns everything Flux's job-list service reports for this job --
    state, result (once inactive), resource usage, timestamps, and more.
    """
    status, resp = await _request("GET", f"/jobs/{jobid}")
    if status != 200:
        return {"error": resp.get("error", f"HTTP {status}"), "status_code": status}
    return resp


@mcp.tool()
async def cancel_job(jobid: str, reason: str | None = None) -> dict:
    """Request cancellation of a job.

    reason: optional human-readable explanation, recorded on the job's
    own event log.
    Returns {"id": ..., "status": "cancel requested"} on success. Note
    this only requests cancellation -- it does not wait for or confirm
    the job has actually stopped; poll get_job_info to check.
    """
    params = {"reason": reason} if reason is not None else None
    status, resp = await _request("DELETE", f"/jobs/{jobid}", params=params)
    if status != 202:
        return {"error": resp.get("error", f"HTTP {status}"), "status_code": status}
    return resp


if __name__ == "__main__":
    mcp.run()
