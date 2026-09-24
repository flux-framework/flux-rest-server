SUBDIRS = t

dist_fluxcmd_SCRIPTS = \
	src/cmd/flux-rest-server.py

dist_fluxlibexec_SCRIPTS = \
	src/libexec/flux-rest-server-ensure.py

if HAVE_SYSTEMD
systemdsystemunit_DATA = \
        systemd/flux-rest-server@.socket \
        systemd/flux-rest-server@.service \
        systemd/flux-rest-server-ensure.socket \
        systemd/flux-rest-server-ensure.service
endif


deb: debian scripts/debbuild.sh
	@$(top_srcdir)/scripts/debbuild.sh $(abs_top_srcdir)

#  End-to-end tests against a Flux system instance.  These are not part of
#  `make check`: they require an installed flux-rest-server (units, polkit,
#  nginx) and a running system instance.  See src/test/docker/docker-run-system.sh,
#  which boots a container providing both and then runs this target.
check-system:
	$(MAKE) $(AM_MAKEFLAGS) -C t check-system
.PHONY: check-system

clean-local:
	@rm -rf debbuild

polkitdir = $(sysconfdir)/polkit-1/rules.d
polkit_DATA = polkit/50-flux-rest-server.rules

dist_doc_DATA = spec/v1/openapi.yaml

docexampledir = $(docdir)/examples
docexample_DATA = \
	nginx/flux-rest-server.conf.example \
	nginx/flux-rest-server-proxy.conf.example \
	nginx/flux-rest-server-insecure.conf.example

EXTRA_DIST = \
	config/tap-driver.sh \
	scripts/openapi-check.py \
	src/test \
	README.md \
	LICENSE \
	NOTICE.LLNS \
	systemd/flux-rest-server@.service.in \
	systemd/flux-rest-server@.socket.in \
	systemd/flux-rest-server-ensure.service.in \
	systemd/flux-rest-server-ensure.socket.in \
	polkit/50-flux-rest-server.rules.in \
	$(docexample_DATA)
