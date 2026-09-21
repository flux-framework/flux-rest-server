ARG IMAGESRC=fluxrm/flux-core:el10
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
#  the base image ships curl-minimal, which conflicts with curl.
#
#  openapi-spec-validator: required by t1003-openapi.t, which validates
#  spec/v1/openapi.yaml and cross-checks it against the routes the server
#  implements.  Installed into the system python3, which is the interpreter
#  `flux python` runs the test under.  --break-system-packages is needed where
#  the distro marks its python externally managed (PEP 668); it is rejected by
#  older pip, hence the fallback ordering.
RUN sudo dnf -y install python3-pip \
 && { command -v curl >/dev/null || sudo dnf -y install curl; } \
 && sudo dnf clean all \
 && { sudo pip3 install openapi-spec-validator \
      || sudo pip3 install --break-system-packages openapi-spec-validator; }

USER $USER
WORKDIR /home/$USER
