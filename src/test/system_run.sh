#!/bin/bash
#
#  Install flux-rest-server into the system-test container and run the system
#  tests.  Meant to be executed inside the container started by
#  src/test/docker/docker-run-system.sh, as the (sudo-capable) test user.
#
#  Everything between the build and `make check-system` is the README's
#  "System mode (nginx + systemd + polkit)" setup, executed.  If that procedure
#  is wrong or goes stale, this script fails.
#
#  Usage: system_run.sh [--setup-only]
#
#  With --setup-only, build and install and configure everything, but do not
#  run the tests.  This is what --interactive uses to hand you a working
#  system instance with the current code installed.
#
#  Environment:
#    JOBS=N   Argument for make -j (default=2)
#
set -e

SETUP_ONLY=
if test "$1" = "--setup-only"; then
	SETUP_ONLY=t
fi

. src/test/checks-lib.sh
. src/test/system-env.sh

JOBS=${JOBS:-2}
MAKE="make --output-sync=target --no-print-directory"

#  Where this release keeps system units.  /usr/lib/systemd/system on EL;
#  ask systemd rather than assuming, so this survives a move to another base.
UNITDIR=$(pkg-config --variable=systemdsystemunitdir systemd 2>/dev/null)
UNITDIR=${UNITDIR:-/usr/lib/systemd/system}

#  Build in-tree, as src/test/checks_run.sh does.  The tree is bind-mounted
#  from the host, so the sharness .log/.trs files land where
#  checks-annotate.sh and the CI annotate step can find them.
#
#  A host-side build may have left a config.status here configured for a
#  different prefix; start from a clean slate rather than failing on it.
checks_group "distclean" sh -c '${MAKE} distclean >/dev/null 2>&1 || true'

checks_group "autogen.sh" ./autogen.sh

#  --with-web-user: the web account is nginx on EL, not the www-data default.
#  That one option drives the socket group, the polkit rule and the service's
#  --allow-user together, so this also exercises the configure knob the README
#  warns against hand-editing around.
#
#  The prefix/libexecdir must match flux-core's so that `flux rest-server`
#  resolves (see the fluxcmddir comment in configure.ac).
checks_group "configure" ./configure \
    --prefix=/usr \
    --libexecdir=/usr/libexec \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --with-web-user=${SYSTEM_TEST_WEB_USER} \
    --with-systemdsystemunitdir=${UNITDIR} \
    || { printf "::error::configure failed\n"; cat config.log; exit 1; }

checks_group "make" ${MAKE} -j ${JOBS}

#  Installs the flux subcommand, the _ensure helper, the four units, the polkit
#  rule and the nginx examples.  There is no RPM packaging, so unlike the
#  Debian path this does not enable anything -- we do that below, which is what
#  debian/rules does via dh_installsystemd.
checks_group "make install" sudo ${MAKE} install

#  Python coverage for the installed scripts.
#
#  This differs from the COVERAGE=t path in checks_run.sh in three ways, all
#  forced by the code running as an installed system service rather than as us:
#
#   - The servers run as other users (User=%i, and the web account for the
#     _ensure helper), so the data directory has to be writable by them --
#     hence a mode 1777 directory rather than one in the build tree.
#   - systemd does not pass our environment on, so COVERAGE_PROCESS_START and
#     PYTHONPATH have to be handed to the units in a drop-in.
#   - Coverage sees the installed copies under $(prefix), not src/, so [paths]
#     maps them back to the source tree for the report.
if test "$COVERAGE" = "t"; then
	checks_group_start "coverage setup"

	coverage -h >/dev/null 2>&1 \
	    || python3 -m pip install --user coverage \
	    || python3 -m pip install --user --break-system-packages coverage
	export PATH=~/.local/bin/:$PATH

	COVERAGE_DIR=/tmp/flux-rest-server-coverage
	sudo rm -rf ${COVERAGE_DIR}
	sudo mkdir -p ${COVERAGE_DIR}
	sudo chmod 1777 ${COVERAGE_DIR}

	#  Activates coverage in any interpreter that imports it, but only when
	#  COVERAGE_PROCESS_START is set -- so only the units we point at it.
	COVERAGE_SITEDIR=${COVERAGE_DIR}/site
	mkdir -p ${COVERAGE_SITEDIR}
	cat <<-EOF >${COVERAGE_SITEDIR}/usercustomize.py
	try:
	    import coverage
	    coverage.process_startup()
	except ImportError:
	    pass
	EOF

	COVERAGE_PKGDIR=$(python3 -c \
	    'import coverage, os; print(os.path.dirname(os.path.dirname(coverage.__file__)))')

	#  The interpreter the servers actually run under is flux-core's, which is
	#  not necessarily the one pip installed coverage for, so put coverage
	#  itself on the path too.
	cat <<-EOF | sudo tee ${COVERAGE_DIR}/coverage.rc >/dev/null
	[run]
	data_file = ${COVERAGE_DIR}/.coverage
	parallel = True
	relative_files = True
	#  Coverage records the installed copies under \$(prefix); map each back to
	#  the file it was built from.  One section per script: within a section
	#  every pattern folds onto the first entry, so a single section would
	#  merge the two into one path.
	[paths]
	server =
	    src/cmd/
	    */libexec/flux/cmd/
	ensure =
	    src/libexec/
	    */libexec/flux/
	[report]
	include =
	    src/*
	EOF

	#  coverage only writes its data file when the interpreter exits normally.
	#  The _ensure helper installs no SIGTERM handler, so systemd's default
	#  KillSignal kills it outright and nothing is written; it does catch
	#  KeyboardInterrupt, so ask systemd for SIGINT instead.  (The server
	#  handles SIGTERM itself and needs no such help, but this is harmless
	#  there -- it treats the two alike.)
	for unit in flux-rest-server@ flux-rest-server-ensure; do
		sudo mkdir -p /etc/systemd/system/${unit}.service.d
		printf '[Service]\nEnvironment=COVERAGE_PROCESS_START=%s\nEnvironment=PYTHONPATH=%s:%s\nKillSignal=SIGINT\n' \
		    "${COVERAGE_DIR}/coverage.rc" \
		    "${COVERAGE_SITEDIR}" "${COVERAGE_PKGDIR}" \
		  | sudo tee /etc/systemd/system/${unit}.service.d/coverage.conf >/dev/null
	done
	checks_group_end
fi

checks_group_start "systemd + polkit setup"
sudo systemctl daemon-reload
#  Restart polkit so it picks up /etc/polkit-1/rules.d/50-flux-rest-server.rules.
#  It is dbus-activated, so it may not be running yet; start covers both.
sudo systemctl restart polkit 2>/dev/null || sudo systemctl start polkit
sudo systemctl enable --now flux-rest-server-ensure.socket
systemctl --no-pager status flux-rest-server-ensure.socket || true
checks_group_end

#  nginx front end, installed from the *shipped doc example* exactly as the
#  README instructs -- so a broken example config fails here.
checks_group_start "nginx setup"
sudo cp /usr/share/doc/flux-rest-server/examples/flux-rest-server-insecure.conf.example \
        /etc/nginx/conf.d/flux-rest-server.conf
sudo htpasswd -bc /etc/nginx/flux.htpasswd "$SYSTEM_TEST_USER_A" "$SYSTEM_TEST_PASSWORD"
sudo htpasswd -b  /etc/nginx/flux.htpasswd "$SYSTEM_TEST_USER_B" "$SYSTEM_TEST_PASSWORD"
#  An account whose name the config's $remote_user regex must reject.
sudo htpasswd -b  /etc/nginx/flux.htpasswd "$SYSTEM_TEST_BADUSER" "$SYSTEM_TEST_PASSWORD"
#  The account running this, so an interactive session can drive the API as
#  itself.  The tests use the accounts above, never this one.
sudo htpasswd -b  /etc/nginx/flux.htpasswd "$(id -un)" "$SYSTEM_TEST_PASSWORD"
sudo nginx -t
sudo systemctl restart nginx
checks_group_end

if test -n "$SETUP_ONLY"; then
	cat <<-EOT

	flux-rest-server is installed and nginx is running.

	  System instance:  owner $(getent passwd "$(flux getattr security.owner)" |
	                            cut -d: -f1), you are $(id -un) (uid $(id -u))

	Drive the API as yourself, the way nginx does:

	  curl -u $(id -un):${SYSTEM_TEST_PASSWORD} \\
	      http://localhost:${SYSTEM_TEST_PORT}/api/v1/

	Submit a job, then confirm the system instance says you own it:

	  curl -u $(id -un):${SYSTEM_TEST_PASSWORD} \\
	      -X POST http://localhost:${SYSTEM_TEST_PORT}/api/v1/jobs \\
	      -H "Content-Type: application/json" \\
	      -d '{"command": ["id", "-un"]}'
	  flux jobs -a
	  flux job attach JOBID

	Run the tests by hand with: make check-system

	EOT
	exit 0
fi

set +e
checks_group "make check-system" ${MAKE} check-system
RC=$?

#  Coverage data is only flushed when a process exits, and the servers linger
#  until --idle-timeout.  Stop them so their data files are written.
if test "$COVERAGE" = "t" && test $RC -eq 0; then
	checks_group_start "coverage report"
	sudo systemctl stop 'flux-rest-server@*.service' \
	                    flux-rest-server-ensure.service 2>/dev/null
	COVERAGE_DIR=/tmp/flux-rest-server-coverage
	rm -f coverage.xml
	#  combine deletes each file as it consumes it, which it cannot do for a
	#  file another user wrote in a sticky directory.  Take a copy we own.
	COMBINE_DIR=$(pwd)/system-coverage
	rm -rf ${COMBINE_DIR} && mkdir -p ${COMBINE_DIR}
	sudo cp ${COVERAGE_DIR}/.coverage.* ${COMBINE_DIR}/ 2>/dev/null
	sudo chown "$(id -u):$(id -g)" ${COMBINE_DIR}/.coverage.* 2>/dev/null
	#  Same config, but writing the combined database somewhere we own.
	sed "s|^data_file = .*|data_file = ${COMBINE_DIR}/.coverage|" \
	    ${COVERAGE_DIR}/coverage.rc >${COMBINE_DIR}/coverage.rc
	export COVERAGE_RCFILE=${COMBINE_DIR}/coverage.rc
	coverage combine ${COMBINE_DIR} \
	  && coverage xml -o coverage.xml \
	  && chmod 444 coverage.xml \
	  && { coverage report || :; }
	RC=$?
	unset COVERAGE_RCFILE
	checks_group_end
fi

if test $RC -ne 0; then
    printf "::error::system tests failed\n"

    #  The server runs under systemd, so anything it writes to stderr lands in
    #  the journal rather than in the sharness .output files.  When a test
    #  fails, that is usually where the reason is.
    #
    #  Surface warnings as annotations first: they appear in the job summary,
    #  rather than inside a collapsed group a reader has to know to open.
    sudo journalctl --no-pager -u 'flux-rest-server*' -o cat 2>/dev/null \
      | grep -iE 'error|warning|traceback' | sort -u \
      | while read -r line; do printf "::warning::%s\n" "$line"; done

    checks_group_start "journal: flux-rest-server units"
    sudo journalctl --no-pager -u 'flux-rest-server*' 2>&1 || true
    checks_group_end
    checks_group_start "journal: nginx"
    sudo journalctl --no-pager -u nginx 2>&1 || true
    checks_group_end
    #  Which units actually failed, and how the instance ended up.
    checks_group_start "systemctl state"
    systemctl --no-pager --failed 2>&1 || true
    systemctl --no-pager status 'flux-rest-server@*.service' 2>&1 || true
    checks_group_end
    checks_group_start "journal: flux.service"
    sudo journalctl --no-pager -u flux.service -n 100 2>&1 || true
    checks_group_end
fi

exit $RC

# vi: ts=4 sw=4 expandtab
