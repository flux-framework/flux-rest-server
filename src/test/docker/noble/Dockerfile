ARG IMAGESRC=fluxrm/flux-core:noble
FROM $IMAGESRC

ARG USER=fluxuser
ARG UID=1000
ARG GID=1000

RUN \
 if test "$USER" != "fluxuser"; then \
      sudo groupadd -g $UID $USER \
   && sudo useradd -g $USER -u $UID -d /home/$USER -m $USER \
   && sudo sh -c "printf \"$USER ALL= NOPASSWD: ALL\\n\" >> /etc/sudoers" \
   && sudo adduser $USER sudo ; \
 fi

#  curl(1): the testsuite drives the server over its unix socket with it.
#  (jq(1) is already in the flux-core base images.)
#
#  openapi-spec-validator: required by t1003-openapi.t, which validates
#  spec/v1/openapi.yaml and cross-checks it against the routes the server
#  implements.  It must go in the system python3, which is the interpreter
#  `flux python` runs the test under.
#
#  There is no python3-openapi-spec-validator package in noble (it arrives in
#  questing), so install with pip.  --break-system-packages is needed because
#  Ubuntu marks its python externally managed (PEP 668), and
#  --ignore-installed because without it pip tries to replace the distro's
#  typing_extensions and fails: a dpkg-installed package has no RECORD file
#  for pip to uninstall.
RUN sudo apt update \
 && sudo apt install -yy curl python3-pip \
 && sudo rm -rf /var/lib/apt/lists/* \
 && sudo pip3 install --break-system-packages --ignore-installed \
        openapi-spec-validator

USER $USER
WORKDIR /home/$USER
