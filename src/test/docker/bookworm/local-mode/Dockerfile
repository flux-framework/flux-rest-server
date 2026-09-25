# Minimal environment for testing flux-rest-server's *local mode* - a
# background subprocess inside a user's own Flux instance, with no nginx,
# systemd, or polkit involved. See ../system-mode-testing/ for the fuller
# environment needed to exercise system mode.
#
# Usage:
#   docker build -t flux-rest-server-local-test .
#   docker run -it --rm flux-rest-server-local-test bash
#
# See README.md in this directory for the smoke-test sequence.

FROM debian:bookworm

# --- build flux-core from source ---
#
# --sysconfdir=/etc is not strictly required for local mode (there's no
# polkit rule involved here), but is included for consistency with the
# system-mode Dockerfile and to avoid surprises if this environment is
# later extended.
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
    jq \
    curl

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
RUN git clone https://github.com/flux-framework/flux-rest-server.git

WORKDIR /build/flux-rest-server
RUN ./autogen.sh
RUN ./configure --prefix=/usr --sysconfdir=/etc
RUN make -j$(nproc)
RUN make -j$(nproc) check || true
RUN make install
RUN ldconfig

WORKDIR /root
CMD ["bash"]
