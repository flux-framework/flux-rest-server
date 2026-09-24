#!/usr/bin/python3
##############################################################
# Copyright 2026 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
##############################################################A

"""flux-rest-server-ensure: systemd unit starter for nginx auth_request

Runs as a socket-activated HTTP service. Nginx calls it via auth_request,
passing the authenticated username. This service ensures the user's
flux-rest-server socket unit is started, then returns 200.

Requires polkit authorization for the calling user (typically nginx/www-data)
to start flux-rest-server@ units.
"""

import os
import re
import socket
import struct
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


_LISTEN_FDS_START = 3
_USERNAME_PATTERN = re.compile(r"^[a-z_][a-z0-9_-]*$")


class _PeerServer(HTTPServer):
    """HTTPServer that accepts connections only from the owning uid, verified
    via SO_PEERCRED. This helper and nginx run as the same web-server account,
    so only that account may trigger unit activation -- independent of the
    socket's file mode."""

    def verify_request(self, request, client_address):
        try:
            creds = request.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("iII")
            )
            _pid, uid, _gid = struct.unpack("iII", creds)
        except OSError:
            return False
        if uid != os.getuid():
            sys.stderr.write(
                f"flux-rest-server-ensure: rejected connection from uid {uid}; "
                f"only uid {os.getuid()} may connect\n"
            )
            return False
        return True


class EnsureHandler(BaseHTTPRequestHandler):
    server_version = "flux-rest-server-ensure/0.1.0"

    def do_GET(self):
        """Handle nginx auth_request by ensuring user's socket unit is started."""
        # nginx forwards the authenticated user via X-Remote-User header
        remote_user = self.headers.get("X-Remote-User", "").strip()

        if not remote_user:
            self.send_error(401, "No authenticated user")
            return

        # Validate username format (security: prevent injection)
        if not _USERNAME_PATTERN.match(remote_user):
            self.send_error(403, f"Invalid username format: {remote_user}")
            return

        unit_name = f"flux-rest-server@{remote_user}.socket"

        try:
            # Start the user's socket unit (idempotent - no-op if already started)
            #
            # N.B. stdout=/stderr=PIPE rather than capture_output=True: systemd
            # runs this script directly, so its #!/usr/bin/python3 shebang picks
            # the system interpreter, which is 3.6 on el8.  capture_output
            # arrived in 3.7, and the resulting TypeError would be swallowed by
            # the except below and reported as a 500.
            result = subprocess.run(
                ["systemctl", "start", unit_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )

            if result.returncode != 0:
                stderr = result.stderr.decode("utf-8", errors="replace")
                self.log_error(f"systemctl start {unit_name} failed: {stderr}")
                self.send_error(500, f"Failed to start {unit_name}: {stderr}")
                return

            # Success - return 200 so nginx proceeds with the proxied request
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK\n")

        except subprocess.TimeoutExpired:
            self.send_error(504, f"Timeout starting {unit_name}")
        except Exception as err:
            self.log_error(f"Unexpected error: {err}")
            self.send_error(500, f"Internal error: {err}")

    def address_string(self):
        # client_address is '' for AF_UNIX peers; the default implementation
        # indexes it as a (host, port) tuple and raises IndexError.
        ca = self.client_address
        return ca[0] if isinstance(ca, tuple) else "unix"

    def log_message(self, format, *args):
        # Log to stderr (captured by systemd journal)
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")


def socket_activated():
    """Check if we're being socket-activated by systemd."""
    return (
        os.environ.get("LISTEN_PID") == str(os.getpid())
        and int(os.environ.get("LISTEN_FDS", "0")) >= 1
    )


def main():
    if not socket_activated():
        print(
            "error: this service requires systemd socket activation",
            file=sys.stderr,
        )
        sys.exit(1)

    # Inherit the listening socket from systemd
    listen_sock = socket.socket(fileno=_LISTEN_FDS_START)
    srv = _PeerServer(("", 0), EnsureHandler, bind_and_activate=False)
    try:
        srv.socket.close()
    except OSError:
        pass
    srv.address_family = listen_sock.family
    srv.socket = listen_sock
    srv.server_address = listen_sock.getsockname()

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
