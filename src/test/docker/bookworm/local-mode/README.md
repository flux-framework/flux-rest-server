# Testing local mode in Docker

This directory contains a minimal, self-contained Docker setup for testing
`flux-rest-server`'s **local mode** - running as a background subprocess
inside a user's own Flux instance, with no nginx, systemd, or polkit
involved. It's the simplest way to sanity-check that flux-rest-server
builds correctly and can talk to a live Flux instance, before moving on to
the fuller [system-mode setup](../system-mode-testing/).

No `--privileged`, cgroup mounts, or systemd-as-PID-1 tricks are needed
here - local mode has no dependency on any of that.

## Quick start

```bash
docker build -t flux-rest-server-local-test .
docker run -it --rm flux-rest-server-local-test bash
```

You'll land in a plain bash shell inside the container, with flux-core and
flux-rest-server already built and installed.

## Smoke test

From inside the container:

```bash
flux start
```

This drops you into a live Flux instance prompt. From there:

```bash
flux exec -r 0 --bg flux rest-server
rundir=$(flux getattr rundir)
curl --unix-socket ${rundir}/rest http://localhost/api/v1/health
curl --unix-socket ${rundir}/rest http://localhost/api/v1/
```

Expected output:

```
{"status": "ok"}
{"name": "flux-rest-server", "user": "root", "broker_version": "...", "rank": 0, "size": 1}
```

The second response confirms the REST server successfully called
`flux_open()` against the live instance - matching broker version, rank,
and size - not just that its own HTTP listener came up.

Type `exit` to leave the Flux instance, and `exit` again to leave the
container.

## Alternative: plain TCP instead of a unix socket

Useful for quick local development/inspection from outside the container:

```bash
flux start flux rest-server --port 8080
```

Then, from another terminal:

```bash
docker exec -it <container-name-or-id> curl http://localhost:8080/api/v1/health
docker exec -it <container-name-or-id> curl http://localhost:8080/api/v1/
```

Add `--verbose` to `flux rest-server` to log each request to stderr.

## Notes

- `--sysconfdir=/etc` is passed to both builds for consistency with the
  system-mode Dockerfile, but doesn't materially affect local mode (there's
  no polkit rule or other `/etc`-dependent config involved here).
- This Dockerfile intentionally does *not* install systemd, nginx, or
  polkit - local mode has no dependency on any of them. If you need to test
  the full nginx -> polkit -> systemd socket activation chain, use
  [`../system-mode-testing/`](../system-mode-testing/) instead.
