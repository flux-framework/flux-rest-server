#  Image for the flux-rest-server system tests (t/t2*.t).
#
#  Boots a real single-node Flux *system* instance under systemd, which is what
#  flux-rest-server is designed to front and what `make check` cannot provide:
#  socket activation, polkit, the per-user setuid, and guest access to an
#  instance owned by somebody else.
#
#  This builds on fluxrm/flux-core:<tag> rather than fluxrm/fluxorama, which is
#  flux-core's equivalent image, for two reasons:
#
#    - fluxorama is published only for amd64, and only from flux-core's el8
#      build.  fluxrm/flux-core:el10 is a multi-arch manifest, so this runs
#      natively on an arm64 developer machine instead of under emulation --
#      which is the difference between a test run of a few minutes and one that
#      times out.
#    - it is about 30 lines of setup, all of it below and all of it specific to
#      what these tests need.  Depending on fluxorama would mean inheriting its
#      ttyd/demo baggage and tracking its changes without gaining anything.
#
#  The system-instance setup below is otherwise the same policy as
#  flux-core's src/test/docker/fluxorama/Dockerfile.
#
ARG IMAGESRC=fluxrm/flux-core:el10
FROM $IMAGESRC

ARG USER=fluxuser
ARG UID=1000
ARG GID=1000

USER root

ENV container=docker
STOPSIGNAL SIGRTMIN+3

#  nginx, httpd-tools:  the front end under test, and htpasswd(1) for its
#                       Basic-auth file.  RHEL's nginx is built
#                       --with-http_auth_request_module, which the shipped
#                       example configs require.
#  polkit:              authorizes the _ensure helper to start per-user units.
#  jq:                  the testsuite parses API responses with it.
#  autoconf/automake/make: flux-rest-server is built from source in-container.
#
#  curl is installed only if absent: on el9+ the base ships curl-minimal, which
#  conflicts with the full curl package (same note as
#  src/test/docker/el8/Dockerfile).
RUN dnf -y install \
      nginx \
      httpd-tools \
      polkit \
      jq \
      autoconf \
      automake \
      make \
      sudo \
 && { command -v curl >/dev/null || dnf -y install curl; } \
 && dnf clean all

#  systemd in a container: drop the units that cannot work without real
#  hardware or an initramfs.  (Recipe from flux-core's fluxorama image.)
RUN (cd /lib/systemd/system/sysinit.target.wants/; \
     for i in *; do [ "$i" = systemd-tmpfiles-setup.service ] || rm -f "$i"; done); \
    rm -f /lib/systemd/system/multi-user.target.wants/*; \
    rm -f /etc/systemd/system/*.wants/*; \
    rm -f /lib/systemd/system/local-fs.target.wants/*; \
    rm -f /lib/systemd/system/sockets.target.wants/*udev*; \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl*; \
    rm -f /lib/systemd/system/basic.target.wants/*; \
    rm -f /lib/systemd/system/anaconda.target.wants/*

#  sssd is sometimes added to nsswitch.conf but is not running here.
RUN sed -i 's/\bsss\b//g' /etc/nsswitch.conf

#  The account the tests run as.  Its uid/gid match the invoking user so the
#  bind-mounted source tree is writable -- on a GitHub runner that is
#  runner/1001, not fluxuser.
RUN if ! id -u $USER >/dev/null 2>&1; then \
        groupadd -g $GID $USER \
     && useradd -g $GID -u $UID -d /home/$USER -m $USER; \
    fi \
 && printf "$USER ALL=(ALL) NOPASSWD: ALL\n" >> /etc/sudoers

#  The system instance owner.
RUN useradd --user-group --system -d /home/flux -m flux || true

#  Spare accounts for the per-user isolation tests (t2001 uses user1/user2).
RUN for i in 1 2 3 4 5; do \
      uid=$(( $UID + 100 + i )); \
      groupadd -g $uid user$i && useradd -g $uid -u $uid -d /home/user$i -m user$i; \
    done

#  System instance configuration: guest access, and job launch via the setuid
#  IMP so jobs run as the submitting user.
COPY imp.toml    /etc/flux/imp/conf.d/imp.toml
COPY exec.toml   /etc/flux/system/conf.d/exec.toml
COPY access.toml /etc/flux/system/conf.d/access.toml

RUN chmod 0644 /etc/flux/imp/conf.d/imp.toml \
               /etc/flux/system/conf.d/exec.toml \
               /etc/flux/system/conf.d/access.toml \
 && chmod 4755 /usr/libexec/flux/flux-imp \
 && systemctl enable flux.service munge.service nginx.service

#  Put back the system bus, which the sockets.target.wants sweep above removed.
#  flux.service does `loginctl enable-linger flux` and starts
#  user@$(id -u flux).service, so systemd-logind must be up, and it reaches the
#  bus to do it.  polkit is on the bus too.
#
#  Only enable what is actually enableable.  dbus is a static unit on el8 and
#  an enabled one on el9+ (where the implementation is dbus-broker), and
#  systemd-logind and polkit are static everywhere: they are bus-activated on
#  demand, so `systemctl enable` on them just prints a paragraph explaining
#  that it did nothing.  Link dbus.socket into sockets.target by hand when it
#  is static, which is what the sweep undid.
RUN if ! systemctl enable dbus.socket 2>/dev/null; then \
        mkdir -p /etc/systemd/system/sockets.target.wants \
     && ln -sf /usr/lib/systemd/system/dbus.socket \
               /etc/systemd/system/sockets.target.wants/dbus.socket; \
    fi \
 && systemctl is-enabled dbus.socket

#  Let systemd manage flux's cgroup rather than resetting it.
RUN mkdir -p /etc/systemd/system/flux.service.d \
 && printf '[Service]\nDelegate=memory cpuset io pids\n' \
      >/etc/systemd/system/flux.service.d/delegate.conf

WORKDIR /home/$USER

#  The base image's entrypoint runs `munged` by hand before exec'ing its
#  command.  Here systemd owns service startup, and that stray munged wins the
#  race for /run/munge/munge.socket.2, leaving munge.service permanently failed
#  -- which surfaces much later as "Did you start munged?" on the first guest
#  job submission.  Clear it so PID 1 is systemd and nothing else.
ENTRYPOINT []
CMD [ "/usr/sbin/init" ]
