# Self-contained environment for testing flux-rest-server's *system mode*
# (nginx -> polkit -> systemd socket activation -> per-user flux-rest-server)
# entirely in userspace, without requiring root/sudo on a real host.
#
# Builds flux-core and flux-rest-server from source, sets up a minimal
# guest-accessible Flux system instance, and wires up nginx + polkit exactly
# as described in the main README's "System mode" section.
#
# Usage:
#   docker build -t flux-rest-server-test .
#   docker run -d --name flux-rest-server-test \
#     --privileged \
#     --tmpfs /run --tmpfs /run/lock \
#     -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
#     flux-rest-server-test
#
# See README.md in this directory for the full smoke-test sequence.

FROM debian:bookworm

# --- systemd + nginx + supporting tools ---
#
# systemd is required as PID 1 (not the default Docker CMD pattern) because
# polkit rule evaluation and socket activation both depend on a real init
# system, not just a single foreground process.
#
# polkitd is required explicitly - installing the flux-rest-server package
# only installs its *rule file*; nothing evaluates that rule without the
# polkit daemon itself also being installed.
RUN apt-get update && apt-get install -y \
    systemd systemd-sysv dbus \
    nginx curl polkitd apache2-utils

# --- build flux-core from source ---
#
# --sysconfdir=/etc is required alongside --prefix=/usr. Without it,
# configure defaults sysconfdir to ${prefix}/etc (i.e. /usr/etc/...), which
# silently breaks anything expecting real /etc paths (notably the polkit
# rule installed by flux-rest-server below).
RUN apt-get update && apt-get install -y \
    git \
    autoconf \
    automake \
    libtool \
    make \
    pkg-config \
    libc6-dev \
    libzmq3-dev \
    uuid-dev \
    libjansson-dev \
    liblz4-dev \
    libarchive-dev \
    libhwloc-dev \
    libsqlite3-dev \
    lua5.1 \
    liblua5.1-dev \
    lua-posix \
    python3-dev \
    python3-cffi \
    python3-ply \
    python3-setuptools \
    python3-yaml \
    python3-sphinx \
    aspell \
    aspell-en \
    time \
    valgrind \
    libmpich-dev \
    jq

WORKDIR /build
RUN git clone https://github.com/flux-framework/flux-core.git

WORKDIR /build/flux-core
RUN ./autogen.sh
RUN ./configure --prefix=/usr --sysconfdir=/etc
RUN make -j$(nproc)
RUN make -j$(nproc) check || true
RUN make install
RUN ldconfig

# --- build flux-rest-server from source ---
RUN apt-get update && apt-get install -y libsystemd-dev

WORKDIR /build
RUN git clone https://github.com/garlick/flux-rest-server.git

WORKDIR /build/flux-rest-server
RUN ./autogen.sh
RUN ./configure --prefix=/usr --sysconfdir=/etc
RUN make -j$(nproc)
RUN make -j$(nproc) check || true
RUN make install
RUN ldconfig

# --- minimal, guest-accessible persistent Flux instance ---
#
# flux-rest-server's system mode assumes a Flux system instance is already
# running and managed by systemd; that's out of scope for flux-rest-server's
# own packaging (it's flux-core's concern). This is a deliberately minimal
# stand-in: single broker, no CURVE cert, no dedicated flux user, no
# multi-node config - just enough for flux_open() to succeed as guest.
# See system.toml and flux-test.service in this directory.
RUN mkdir -p /etc/flux/system/conf.d
COPY system.toml /etc/flux/system/conf.d/system.toml

COPY flux-test.service /lib/systemd/system/flux-test.service
RUN systemctl enable flux-test.service

# --- point flux-rest-server@.service at the instance above ---
#
# The installed unit already ships this line commented out; we just
# uncomment it rather than hand-editing anything else in the unit.
RUN sed -i \
    's|^# Environment=FLUX_URI=local:///run/flux/local|Environment=FLUX_URI=local:///run/flux/local|' \
    /usr/lib/systemd/system/flux-rest-server@.service

# make install (unlike the .deb package's postinst) does not enable this
# socket automatically - do it explicitly.
RUN systemctl enable flux-rest-server-ensure.socket

# --- nginx as the outer layer ---
#
# Uses the project's own flux-rest-server-insecure.conf.example verbatim
# (local testing only - plain HTTP + Basic auth, no TLS). See
# flux-rest-server.conf in this directory.
COPY flux-rest-server.conf /etc/nginx/conf.d/flux-rest-server.conf

# --- test accounts representing real end users, distinct from the
#     web-server account (www-data) ---
#
# www-data is the *proxy* identity - nginx runs as it, and it's what
# polkit/--allow-user check against. It should never itself be a valid
# Basic Auth login. alice represents a real end user: her login becomes
# $remote_user -> X-Remote-User: alice -> flux-rest-server@alice.service,
# actually running as her UID, not www-data's. bob exists purely to prove
# isolation: some *other* non-proxy user must be rejected when connecting
# directly to alice's socket.
RUN useradd -m alice
RUN useradd -m bob

# CHANGEME: replace with a real generated password before use. This is left
# as an obvious placeholder rather than a working credential on purpose -
# copy/pasting this Dockerfile as-is will produce a login that doesn't work,
# by design, so nobody accidentally ships a known password.
RUN htpasswd -cb /etc/nginx/flux.htpasswd alice CHANGEME_generate_a_real_password

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
