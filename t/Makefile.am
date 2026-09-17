AM_TESTS_ENVIRONMENT = \
	export SHARNESS_BUILD_DIRECTORY="$(abs_top_builddir)";\
	export SHARNESS_TEST_SRCDIR="$(abs_top_srcdir)/t";

TEST_EXTENSIONS = .t
T_LOG_DRIVER = env AM_TAP_AWK='$(AWK)' $(SHELL) \
	$(top_srcdir)/config/tap-driver.sh

clean-local:
	rm -fr trash-directory.* test-results .prove *.broker.log *.output

TESTS = \
	t0000-sharness.t \
	t1000-basic.t \
	t1001-security.t \
	t1002-job-submit.t \
	t1003-openapi.t \
	t1004-jobs-cancel.t

EXTRA_DIST = \
	$(TESTS) \
	sharness.sh \
	sharness.d
