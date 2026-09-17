ARG IMAGESRC=fluxrm/flux-core:el8
FROM $IMAGESRC

ARG USER=fluxuser
ARG UID=1000
ARG GID=1000

RUN \
 if test "$USER" != "fluxuser"; then \
      sudo groupadd -g $UID $USER \
   && sudo useradd -g $USER -u $UID -d /home/$USER -m $USER \
   && sudo sh -c "printf \"$USER ALL= NOPASSWD: ALL\\n\" >> /etc/sudoers" \
   && sudo usermod -G wheel $USER \
   && sudo usermod -G wheel fluxuser ; \
 fi

#  curl(1): the testsuite drives the server over its unix socket with it.
#  (jq(1) is already in the flux-core base images.)  Install only if missing:
#  on RHEL9+ the base image ships curl-minimal, which conflicts with curl.
#
#  python39: /usr/bin/python3 on el8 is 3.6, but configure.ac requires
#  AM_PATH_PYTHON([3.8]).  Install a newer interpreter and point configure at
#  it via $PYTHON below.  Nothing here is built or installed with $(PYTHON):
#  the scripts run under flux-core's interpreter (`flux rest-server`, `flux
#  python`), which stays 3.6.  So this satisfies configure without changing
#  what the testsuite actually exercises.
RUN sudo yum -y install python39 \
 && { command -v curl >/dev/null || sudo yum -y install curl; } \
 && sudo yum clean all
ENV PYTHON=/usr/bin/python3.9

#  N.B. no openapi-spec-validator here: it requires Python >= 3.8 and so
#  cannot be installed for the el8 flux-core interpreter (3.6).
#  t1003-openapi.t detects that and skips.  Spec conformance is still checked
#  by the `openapi` workflow job, and route coverage by the other images.

USER $USER
WORKDIR /home/$USER
