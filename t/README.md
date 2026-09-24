# flux-rest-server testsuite

The tests are [sharness](https://github.com/chriscool/sharness) scripts driven
by automake.

## API tests

`t0000`–`t1xxx`, run by `make check`. Each starts its own instance with
`flux start` and talks to the server over a socket it creates itself.

To run one by hand:

```sh
cd t
./t1002-job-submit.t --verbose --debug
```

Needs `curl` and `jq`. `t1003-openapi.t` also needs `pyyaml` and
`openapi-spec-validator` importable by flux-core's Python, and skips itself if
they are missing.

## System tests

`t2xxx`, which test system mode: the systemd units, socket activation, the
polkit rule, the per-user setuid, and the nginx configs in `nginx/`. They need
an installed package and a Flux system instance, so they cannot run under
`make check`. CI runs them.

They are listed in `SYSTEM_TESTS` rather than `TESTS` in `Makefile.am`, and run
by `make check-system`.

### Running them

This builds a container, boots a system instance in it, installs
flux-rest-server, runs the tests, and removes the container:

```sh
./src/test/docker/docker-run-system.sh
```

To install the current code and get a shell instead of running the tests:

```sh
./src/test/docker/docker-run-system.sh -I
```

It prints how to drive the API as yourself. `make check-system` runs the tests
from there.

Options: `-j N` for parallel make, `-i IMAGE` for a different base image,
`--no-cache` to force an image rebuild.

### Requirements

**podman** — not docker, since the container runs systemd as PID 1. Everything
else is installed inside the container by `src/test/docker/system/Dockerfile`.

On an Ubuntu host, AppArmor blocks PAM inside the container and the Flux
instance will not start. CI unloads the profiles; the script does not, since
that changes your machine rather than the container:

```sh
sudo apparmor_parser -R /etc/apparmor.d/unix-chkpwd
sudo apparmor_parser -R /etc/apparmor.d/sudo
```

## Adding a test

Copy the top of an existing script, make it executable, and add it to `TESTS`
(or `SYSTEM_TESTS`) in `Makefile.am`.

Bound every `curl` with `$CURL_TIMEOUT_ARGS`. Without a timeout a stalled
client burns the whole `FLUX_TEST_TIMEOUT` and the script is killed mid-stream,
which is reported as a missing test plan rather than a failure. When a command
is expected to fail, assert its exact exit code with `test_expect_code` so a
timeout cannot pass for the failure under test.

Helpers live in `sharness.d/` (sourced automatically) and `scripts/`.
