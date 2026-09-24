AC_PREREQ([2.63])
AC_INIT([flux-rest-server],
        m4_esyscmd([test -n "$FLUX_REST_SERVER_VERSION" && printf $FLUX_REST_SERVER_VERSION || git describe --always | awk '/.*/ {sub(/^v/, ""); printf "%s",$1; exit}']))
AC_CONFIG_AUX_DIR([config])
AC_CONFIG_MACRO_DIR([config])
AC_CONFIG_SRCDIR([README.md])

AM_INIT_AUTOMAKE([foreign])
AM_SILENT_RULES([yes])

AC_PROG_INSTALL
# Both scripts run under the interpreter flux-core was built with: flux(1)
# execs flux-rest-server.py under its compiled-in PYTHON_INTERPRETER, which is
# also the only interpreter the flux bindings are importable from, and the
# _ensure helper runs under the system python3 named in its shebang.  Neither
# is $(PYTHON).  So this must be the oldest interpreter flux-core ships on --
# 3.6 on el8 -- or configure accepts a version the code will never see, and
# 3.7+ features pass the build and fail at runtime.
AM_PATH_PYTHON([3.6])

AX_FLUX_CORE

# systemd unit directory (--with-systemdsystemunitdir) + HAVE_SYSTEMD; the
# default is prefix-relative so distcheck installs under its own prefix.
RRA_WITH_SYSTEMD_UNITDIR

# Account/group the web server (nginx) fronting this service runs as.  Used to
# authorize the _ensure helper via polkit and to group-restrict the per-user
# sockets so only the web server may connect.  Defaults match Debian/Ubuntu;
# pass e.g. --with-web-user=nginx on RHEL/Fedora.
AC_ARG_WITH([web-user],
    [AS_HELP_STRING([--with-web-user=USER],
        [account the web server runs as @<:@default=www-data@:>@])],
    [web_user=$withval], [web_user=www-data])
AC_ARG_WITH([web-group],
    [AS_HELP_STRING([--with-web-group=GROUP],
        [group permitted to connect to the sockets @<:@default=web-user@:>@])],
    [web_group=$withval], [web_group=$web_user])
AC_SUBST([WEB_USER], [$web_user])
AC_SUBST([WEB_GROUP], [$web_group])

# Our flux subcommand and libexec helper must live in flux-core's command and
# libexec directories for `flux rest-server` to resolve them. flux-core uses
# $libexecdir/flux[/cmd], so we use the same formula, honoring --prefix /
# --libexecdir (configure with the same values as flux-core; the Debian package
# does this automatically via dh's multiarch --libexecdir).
fluxcmddir=$libexecdir/flux/cmd
fluxlibexecdir=$libexecdir/flux
# Fully expand ${prefix}/${exec_prefix} so these can be substituted as absolute
# paths into non-Makefile files (e.g. the systemd unit ExecStart); config.status
# does not expand make-time variables.
adl_RECURSIVE_EVAL([$fluxcmddir], [fluxcmddir])
adl_RECURSIVE_EVAL([$fluxlibexecdir], [fluxlibexecdir])
AC_SUBST(fluxcmddir)
AC_SUBST(fluxlibexecdir)

AC_CONFIG_FILES([
  Makefile
  t/Makefile
  systemd/flux-rest-server@.service
  systemd/flux-rest-server@.socket
  systemd/flux-rest-server-ensure.service
  systemd/flux-rest-server-ensure.socket
  polkit/50-flux-rest-server.rules
])

AC_OUTPUT
