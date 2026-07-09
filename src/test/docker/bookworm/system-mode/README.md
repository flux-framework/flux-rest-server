# Testing system mode in Docker (no sudo/root required on the host)

This directory contains a self-contained Docker setup for exercising
`flux-rest-server`'s full **system mode** trust chain -
`nginx -> auth_request -> polkit -> systemd socket activation -> per-user
flux-rest-server -> flux_open() as guest` - without requiring root or sudo
access on a real host. It's intended for anyone who wants to validate or
understand the system-mode design without deploying onto a real Flux
cluster.

For a much simpler setup that just tests local mode (no nginx/systemd/polkit
required at all), see [`../local-mode-testing/`](../local-mode-testing/)
instead - it's a good first step before working through the fuller
environment here.

Everything runs inside a single privileged container, which is what makes
this possible without host-level root: the container gets a disposable
"fake machine" where systemd, polkit, and nginx can all run for real, with
real root *inside the container*, without touching the actual host.

## Files in this directory

| File | Purpose |
|---|---|
| `Dockerfile` | Builds flux-core and flux-rest-server from source, sets up a minimal Flux system instance, wires up polkit and nginx |
| `system.toml` | Flux config enabling guest connections (`allow-guest-user = true`) |
| `flux-test.service` | systemd unit for a minimal, persistent, guest-accessible Flux system instance |
| `flux-rest-server.conf` | nginx config (copy of the project's own `flux-rest-server-insecure.conf.example`) |

## Quick start

```bash
docker build -t flux-rest-server-test .

docker run -d --name flux-rest-server-test \
  --privileged \
  --tmpfs /run \
  --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  flux-rest-server-test

sleep 3
```

`--privileged` and the `/sys/fs/cgroup` mount are required for systemd to
run properly as PID 1 inside the container; `--tmpfs /run` and
`--tmpfs /run/lock` give it the writable runtime directories it expects.

Set a real password for the test end-user account, `alice` (the Dockerfile
intentionally installs a placeholder that won't work, so this step is
required before the smoke test below will succeed). Note this is `alice`,
not `www-data` - `www-data` is the proxy/web-server identity nginx itself
runs as, and should never be a valid login:

```bash
docker exec -it flux-rest-server-test htpasswd -b /etc/nginx/flux.htpasswd alice <your-test-password>
```

## Smoke test - full chain, end to end

This single request exercises every layer of system mode in one shot,
logged in as `alice` - a real end user, distinct from the `www-data`
proxy account:

```bash
docker exec -it flux-rest-server-test \
  curl -u alice:<your-test-password> http://localhost:8080/api/v1/health
# -> {"status": "ok"}

docker exec -it flux-rest-server-test \
  curl -u alice:<your-test-password> http://localhost:8080/api/v1/
# -> {"name": "flux-rest-server", "user": "alice", "broker_version": "...", "rank": 0, "size": 1}
```

`"user": "alice"` is the meaningful part of that response - it confirms
`flux_open()` ran as the actual end user who authenticated, not as the
`www-data` proxy account that relayed the request.

### Negative test: confirm per-user isolation, not just that it works

A third, unrelated user (`bob` - also created by the Dockerfile) should be
refused when connecting directly to `alice`'s socket, bypassing nginx
entirely:

```bash
docker exec -it --user bob flux-rest-server-test \
  curl --unix-socket /run/flux-rest-server/alice.sock http://localhost/api/v1/health
# -> should fail (connection reset / rejected) - only www-data may connect,
#    per --allow-user=www-data and the SO_PEERCRED check
```

If this succeeds instead of failing, something is wrong with the
per-user socket's permissions or the `--allow-user` configuration - it
should never be possible for an arbitrary user to reach another user's
socket directly.

### Matching upstream's own smoke test exactly

The [main README](https://github.com/flux-framework/flux-rest-server) shows
this three-command smoke test for system mode:

```bash
# auth_request stand-in: the helper runs (as www-data, authorized by polkit)
#   systemctl start flux-rest-server@$USER.socket
sudo -u www-data curl -s --unix-socket /run/flux-rest-server/ensure.sock \
    -H "X-Remote-User: $USER" http://localhost/

# proxy_pass stand-in: the first connection activates the per-user service
sudo -u www-data curl --unix-socket /run/flux-rest-server/$USER.sock \
    http://localhost/api/v1/health
sudo -u www-data curl --unix-socket /run/flux-rest-server/$USER.sock \
    http://localhost/api/v1/
```

Two adaptations for this container: no `sudo` is installed, so
`docker exec --user www-data` is used instead - it achieves the identical
result (`SO_PEERCRED` checks the kernel's actual view of the connecting
process's UID, not anything env-var-based, so this is not a weaker
substitute); and `$USER` is written out explicitly as `alice`, since it
isn't guaranteed to be populated inside a `docker exec` session the way it
would be in a real interactive login shell:

```bash
docker exec -it --user www-data flux-rest-server-test \
  curl -s --unix-socket /run/flux-rest-server/ensure.sock \
  -H "X-Remote-User: alice" http://localhost/
# -> OK

docker exec -it --user www-data flux-rest-server-test \
  curl --unix-socket /run/flux-rest-server/alice.sock http://localhost/api/v1/health
# -> {"status": "ok"}

docker exec -it --user www-data flux-rest-server-test \
  curl --unix-socket /run/flux-rest-server/alice.sock http://localhost/api/v1/
# -> {"name": "flux-rest-server", "user": "alice", "broker_version": "...", "rank": 0, "size": 1}
```

**Confirming `SO_PEERCRED` is real enforcement, not just app-level logic:**
`alice` herself - a valid end user, but not `www-data` - should still be
refused when trying to reach `ensure.sock` directly:

```bash
docker exec -it --user alice flux-rest-server-test \
  curl -v --unix-socket /run/flux-rest-server/ensure.sock \
  -H "X-Remote-User: alice" http://localhost/
# -> curl: (7) Failed to connect... Permission denied
```

This actually fails *earlier* than root's rejection did in step 5 below -
`curl` can't even open the connection, because the socket file itself is
`0660 root:www-data` (set via `SocketGroup`/`SocketMode` in
`flux-rest-server@.socket`). Root gets refused by an app-level
`--allow-user` check after connecting; a non-`www-data`, non-root user like
`alice` gets refused by plain filesystem permissions before a connection is
even established. Both layers independently enforce the same guarantee:
only `www-data` may connect.

## Step-by-step verification (for debugging or understanding each layer)

If the end-to-end test above doesn't pass, or you want to understand each
piece individually, work through these in order - each isolates one layer
of the chain.

### 1. systemd itself

```bash
docker exec -it flux-rest-server-test systemctl status
# -> State: running, Failed: 0 units
```

### 2. nginx, as a systemd-managed service

```bash
docker exec -it flux-rest-server-test systemctl status nginx
# -> Active: active (running)
```

### 3. The persistent Flux instance

```bash
docker exec -it flux-rest-server-test systemctl status flux-test.service
# -> Active: active (running)

docker exec -it flux-rest-server-test flux getattr size
# -> 1

# guest access specifically (a different user than whoever owns the broker):
docker exec -it --user nobody flux-rest-server-test flux getattr size
# -> 1
```

### 4. flux-rest-server in local mode (no nginx/polkit/systemd involved)

```bash
docker exec -it flux-rest-server-test bash
flux start
# at the flux prompt:
flux exec -r 0 --bg flux rest-server
rundir=$(flux getattr rundir)
curl --unix-socket ${rundir}/rest http://localhost/api/v1/health
curl --unix-socket ${rundir}/rest http://localhost/api/v1/
exit  # leaves the flux instance
exit  # leaves the container shell
```

### 5. systemd socket activation, manually (bypassing polkit)

```bash
docker exec -it flux-rest-server-test systemctl start flux-rest-server@alice.socket
docker exec -it flux-rest-server-test systemctl status flux-rest-server@alice.socket
# -> Active: active (listening), Triggers: flux-rest-server@alice.service

# The socket/service are named for alice (the end user, %i in the unit),
# but only www-data (the proxy account) is allowed to connect to it -
# root is intentionally refused too by SO_PEERCRED:
docker exec -it --user www-data flux-rest-server-test \
  curl --unix-socket /run/flux-rest-server/alice.sock http://localhost/api/v1/health
# -> {"status": "ok"}

docker exec -it flux-rest-server-test systemctl status flux-rest-server@alice.service
# -> Active: active (running)
```

### 6. polkit / the `_ensure` helper (the real activation path)

```bash
docker exec -it flux-rest-server-test systemctl stop flux-rest-server@alice.socket
docker exec -it flux-rest-server-test systemctl stop flux-rest-server@alice.service

# _ensure is called by www-data (the proxy), naming alice (the real end
# user) via X-Remote-User - these are deliberately different identities:
docker exec -it --user www-data flux-rest-server-test \
  curl --unix-socket /run/flux-rest-server/ensure.sock \
  -H "X-Remote-User: alice" http://localhost/
# -> 200 OK, body: "OK"

docker exec -it flux-rest-server-test systemctl status flux-rest-server@alice.socket
# -> Active: active (listening) - triggered by the _ensure call above, not manually
```

### 7. nginx as the front end

Covered by the "Smoke test" section above.

## Notes, caveats, and things deliberately simplified

- **This uses a minimal, non-production Flux system instance** (single
  broker, no CURVE certificate, no dedicated `flux` system user, no
  multi-node config - see `system.toml`/`flux-test.service`). Real
  deployments should follow the
  [Flux Admin Guide](https://flux-framework.readthedocs.io/projects/flux-core/en/stable/guide/admin_config.html)
  for actual production configuration. flux-rest-server's own design
  doesn't care how the underlying instance was set up, only that
  `flux_open()` as guest succeeds against it - which is all this minimal
  instance needs to prove.
- **`-Sbroker.rc2_none` is required** when starting the broker under
  systemd. Without it, the broker defaults to launching an interactive
  shell as its "initial program," which fails immediately with
  `stdin is not a tty - can't run interactive shell` when there's no tty
  attached (as is always the case under systemd).
- **`ExecStartPre=/bin/mkdir -p -m 755 /run/flux` is required.** The broker
  creates its rundir as `0700` by default; without pre-creating it with
  looser permissions, guest connections are refused at the filesystem level
  before Flux's own `allow-guest-user` setting is ever consulted.
- **`--sysconfdir=/etc` must be passed explicitly** alongside
  `--prefix=/usr` when configuring both flux-core and flux-rest-server.
  Without it, `sysconfdir` defaults to `${prefix}/etc` (i.e. `/usr/etc/...`),
  which silently breaks the polkit rule's installed location - polkit only
  reads from `/etc/polkit-1/rules.d/`, not `/usr/etc/polkit-1/rules.d/`.
- **`polkitd` must be installed explicitly.** Installing flux-rest-server
  only installs its polkit *rule file*; nothing evaluates that rule unless
  the polkit daemon package itself is also present. Its absence produces a
  misleading `500 ... Access denied` from the `_ensure` helper that looks
  like a rule-authoring problem but is actually a missing package.
- **`flux-rest-server-ensure.socket` and `flux-test.service` must be
  enabled explicitly** (`systemctl enable`) when building this way. The
  project's `.deb` packaging enables `flux-rest-server-ensure.socket`
  automatically via its `postinst` script; building from source with plain
  `make install` (as this Dockerfile does, to sidestep needing
  `dpkg-buildpackage`/`debhelper` tooling) skips that step, so it must be
  done manually.
- The Basic Auth password is intentionally left as an obvious non-working
  placeholder (`CHANGEME_generate_a_real_password`) in the Dockerfile rather
  than a real credential, so nobody accidentally ships a known password by
  copy/pasting this as-is. Set a real one with `htpasswd` after building
  (see "Quick start" above) before running the smoke test.
