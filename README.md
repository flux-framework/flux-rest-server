[![codecov](https://codecov.io/gh/flux-framework/flux-rest-server/branch/main/graph/badge.svg)](https://codecov.io/gh/flux-framework/flux-rest-server)

# flux-rest-server

A proof of concept HTTP front-end for Flux that demonstrates a
[straw man design](REST_API.md) for a per-user, socket activated REST server.

The package provides `flux-rest-server` which can be used in two modes:

In **local mode** `flux-rest-server` is started as a background subprocess in
a user's instance and provides a UNIX domain socket in Flux's `$rundir` serving
REST queries for the user's local instance (e.g. the initial program).  The
server's lifetime is tied to that of the instance.

In **system mode**, an `nginx` reverse proxy server handles
enterprise-authenticated requests from off-cluster and spawns a
`flux-rest-server` for the user via socket activation.  The server connects
to the system instance as a guest, and could browse to the user's own
instances as the instance owner using the Flux API (e.g. `ssh://`).
The server's lifetime is based on an HTTP idle timeout.

The key element of this design is that enterprise security relies on the
`nginx` and `systemd` configuration rather than the API server itself.
The API server, executing as the end user, fits comfortably within Flux's
security model.  Critically, running as the user, it has the capability
to sign HTTP job requests via MUNGE using the user's credentials.

## Build and Test

This project uses autotools so the standard targets work:

```sh
./autogen.sh
./configure
make
make check
```

For system testing on Debian, build a test deb:

```sh
make deb
sudo dpkg -i debbuild/flux-rest-server_*.deb
```

## Local mode (running directly)

By default, `flux rest-server` creates a Unix domain socket at `${rundir}/rest` inside your Flux instance:

```sh
flux start
# In the Flux instance:
flux exec -r 0 --bg flux rest-server
rundir=$(flux getattr rundir)
curl --unix-socket ${rundir}/rest http://localhost/api/v1/health
curl --unix-socket ${rundir}/rest http://localhost/api/v1/
```

For TCP access (e.g., development), use `--port`:

```sh
flux start flux rest-server --port 8080
```

Then from another terminal:

```sh
curl http://localhost:8080/api/v1/health  | jq
curl http://localhost:8080/api/v1/        | jq
```

Add `--verbose` to log each request to stderr.

## End-to-end system tests

`make check` cannot test system mode, which needs an installed package and a
Flux system instance. Those tests run in a container instead — see
[t/README.md](t/README.md).

## System mode (nginx + systemd + polkit)

For production deployments, `flux-rest-server` is designed to run as a per-user service behind an nginx reverse proxy. The architecture provides:

- **TLS termination** and **authentication** (Kerberos, LDAP, etc.) via nginx
- **Per-user isolation**: each user gets their own `flux-rest-server` process
- **On-demand activation**: systemd socket activation starts services only when needed
- **Privilege separation**: nginx (unprivileged) can start user services via polkit

### Architecture

```
Client → nginx (TLS + auth) → systemd socket → flux-rest-server (as user) → system Flux instance
```

### Setup steps

These steps assume a Debian system where nginx runs as `www-data` (the build
default). Installing the package sets up everything except the nginx front end:
it installs the systemd units and the polkit rule (which authorizes `www-data`
to start `flux-rest-server@` units), and it enables
`flux-rest-server-ensure.socket`.

> To front this with a web server that runs as a different account, rebuild with
> `./configure --with-web-user=NAME` (and optionally `--with-web-group=NAME`).
> That single option drives the socket group, the polkit rule, and the service's
> `--allow-user` together — do not hand-edit the installed unit, or the three
> will fall out of sync.

1. **Verify the on-demand helper is active** (the package enables it):

   ```sh
   systemctl status flux-rest-server-ensure.socket
   ```

2. **Smoke-test per-user activation the way nginx will.** Two steps mirror what
   nginx does: first the `auth_request` to the `_ensure` helper (which brings the
   user's socket up), then the proxied request. Run both *as the web-server
   user* (`www-data`) — connections are restricted to that account by the
   socket's `0660 root:www-data` mode and by an `SO_PEERCRED` check, so
   connecting as yourself or as root is intentionally refused:

   ```sh
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

   (Equivalently, skip the helper and start the socket directly with
   `sudo systemctl start flux-rest-server@$USER.socket`.)

   `/api/v1/health` is a pure liveness check; `/api/v1/` additionally confirms
   the service can open Flux — it calls `flux_open()`, reaching the **system**
   instance as that user (guest role). If it returns `503 flux unavailable`, set
   `FLUX_URI` in `/lib/systemd/system/flux-rest-server@.service` (see the
   commented example there).

3. **Configure nginx** as the front end. Three example configs are installed
   under `examples/` in the package docs (e.g.
   `/usr/share/doc/flux-rest-server/examples/`):

   - `flux-rest-server.conf.example` — production: TLS plus a site auth method
     (Kerberos/LDAP/mTLS). Set your hostname, certificate paths, and an auth
     method that populates `$remote_user`.
   - `flux-rest-server-proxy.conf.example` — behind a **trusted upstream proxy**
     (e.g. LC Wormhole) that has already authenticated the user: mutual TLS
     verifies the proxy, and the user it asserts is mapped to the per-user
     socket.
   - `flux-rest-server-insecure.conf.example` — **local testing only**: plain
     HTTP with HTTP Basic auth, no TLS (see the warning at the top of the file).

   All proxy `/api/` to the per-user socket and gate it with an `auth_request`
   to the `_ensure` helper; they differ only in how `$remote_user` is
   established. nginx must run as the web-server account the package was built
   for (`www-data` on Debian).

   Each is an nginx **`server` block**, so install it inside the `http{}`
   context — not as `nginx.conf` (a bare `server{}` there is invalid). On Debian
   the stock `nginx.conf` includes `conf.d/*.conf`, so:

   ```sh
   sudo cp /usr/share/doc/flux-rest-server/examples/flux-rest-server-insecure.conf.example \
           /etc/nginx/conf.d/flux-rest-server.conf
   sudo nginx -t && sudo systemctl reload nginx
   ```

The `_ensure` helper (`flux-rest-server-ensure.socket`, listening at
`/run/flux-rest-server/ensure.sock`) is already enabled by the package. When
nginx makes an `auth_request` to `/_ensure`, the helper starts that user's
`flux-rest-server@USER.socket` unit (authorized by the polkit rule). Per-user
sockets are **not** pre-enabled — they start on demand as users connect.

### How it works

1. nginx receives the HTTPS request, authenticates the user, sets `$remote_user`.
2. nginx's `auth_request` calls the `_ensure` helper, which — as the web-server
   user, authorized by the polkit rule — runs `systemctl start
   flux-rest-server@$remote_user.socket`. This creates the per-user listening
   socket if it isn't already up (the per-user sockets are not pre-enabled, so
   something has to start them on demand; that's the helper's whole job).
3. nginx proxies the request to `/run/flux-rest-server/$remote_user.sock`.
4. The first connection activates `flux-rest-server@$remote_user.service`, which
   systemd starts **as that user** (`User=%i`).
5. The server inherits the listening socket and calls `flux_open()` — reaching
   the **system** Flux instance as that user (guest role). Navigating into the
   user's own sub-instances (the instance hierarchy) is future work.
6. nginx relays the response.

The `.socket` (step 2) creates the socket; the connection (step 4) is what
auto-starts the service — that two-hop split is why a listener must exist before
a connection can activate anything.

### Service lifetime

Once activated, `flux-rest-server@USER.service` serves the inherited socket
across connections. The packaged unit passes **`--idle-timeout=5m`**, so an idle
per-user server exits after 5 minutes with no connection and systemd
transparently re-activates it on the next request (the `.socket` stays up). Change
the value in `ExecStart` (`/lib/systemd/system/flux-rest-server@.service`) — it
is a Flux standard duration (e.g. `30s`, `1h`); use `infinity` to disable. Stop
one immediately with:

```sh
sudo systemctl stop flux-rest-server@$USER.service   # and/or @.socket
```

See `REST_API.md` for the full design.

## License

LGPL-3.0. See `LICENSE` and `NOTICE.LLNS`.
