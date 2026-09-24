##
# Constants shared between src/test/system_run.sh, which sets the container up,
# and t/t2*.t, which test it.  Sourced by both so the two cannot drift.
#
# These describe a throwaway container, not a deployment: the password is in
# git on purpose, and the front end is plain HTTP (see
# nginx/flux-rest-server-insecure.conf.example).
##

# nginx listen port, from the insecure example config.
SYSTEM_TEST_PORT=8080

# Basic-auth password for every account in /etc/nginx/flux.htpasswd.
SYSTEM_TEST_PASSWORD=testpw

# The account the web server runs as (configure --with-web-user).  el8 nginx
# runs as "nginx"; the configure default, www-data, is Debian's.
SYSTEM_TEST_WEB_USER=nginx

# Two real accounts for the nginx tests.  fluxorama creates user1..user5.
#
# t2001 drives these and never touches $USER, while t2000 drives $USER and
# never touches these: the two files share no systemd units, so automake's
# parallel harness cannot race them.
SYSTEM_TEST_USER_A=user1
SYSTEM_TEST_USER_B=user2

# An htpasswd entry whose name the shipped nginx config must reject with 403
# before it is ever interpolated into a socket path.  Not a local account.
SYSTEM_TEST_BADUSER=Bad.User

# Where the units put the per-user sockets.
SYSTEM_TEST_SOCKDIR=/run/flux-rest-server
