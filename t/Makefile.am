AM_TESTS_ENVIRONMENT = \
	export SHARNESS_BUILD_DIRECTORY="$(abs_top_builddir)";\
	export SHARNESS_TEST_SRCDIR="$(abs_top_srcdir)/t";

TEST_EXTENSIONS = .t
T_LOG_DRIVER = env AM_TAP_AWK='$(AWK)' $(SHELL) \
	$(top_srcdir)/config/tap-driver.sh

#  automake's own cleanup only covers $(TEST_LOGS), which is derived from
#  TESTS, so the system tests' logs have to be named here.
clean-local:
	rm -fr trash-directory.* test-results .prove *.broker.log *.output
	rm -f $(SYSTEM_TESTS:.t=.log) $(SYSTEM_TESTS:.t=.trs)

TESTS = \
	t0000-sharness.t \
	t1000-basic.t \
	t1001-security.t \
	t1002-job-submit.t \
	t1003-openapi.t \
	t1004-jobs-cancel.t \
	t1006-shutdown.t \
	t1007-timeout.t

#  System tests.  These need a Flux *system* instance and an installed
#  flux-rest-server (systemd units, polkit rule, nginx), so they are
#  deliberately NOT in TESTS: `make check` cannot run them.  `make
#  check-system` runs only them, inside the container built by
#  src/test/docker/docker-run-system.sh.
#
#  Keeping them out of TESTS rather than gating them on an environment
#  variable means they can never silently skip -- if you asked for them and the
#  environment is wrong, they fail.
SYSTEM_TESTS = \
	t2000-system-activation.t \
	t2001-system-nginx.t

#  TEST_EXTENSIONS gives automake a generic .t.log rule, so overriding TESTS on
#  the command line works for scripts that are not in TESTS.
check-system:
	$(MAKE) $(AM_MAKEFLAGS) check TESTS='$(SYSTEM_TESTS)'
.PHONY: check-system

EXTRA_DIST = \
	$(TESTS) \
	$(SYSTEM_TESTS) \
	sharness.sh \
	sharness.d \
	scripts
