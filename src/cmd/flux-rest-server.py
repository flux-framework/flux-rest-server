#!/usr/bin/python3
##############################################################
# Copyright 2026 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
##############################################################

"""flux-rest-server: a minimal, stdlib-only HTTP front-end for Flux."""

import argparse
import errno
import json
import os
import pwd
import socket
import struct
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

import flux
import flux.job
import flux.util

API_VERSION = "v1"
SERVER_NAME = "flux-rest-server"
_PREFIX = f"/api/{API_VERSION}"
_MAX_BODY_SIZE = 1024 * 1024  # 1 MiB; sanity cap, not a considered limit

_handle = None


def _flux():
    """Return a cached Flux handle, creating it on first use.

    Raises OSError if no broker is reachable.
    """
    global _handle
    if _handle is None:
        _handle = flux.Flux()
    return _handle


def _user():
    """The user this server runs as (and connects to Flux as)."""
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return str(os.getuid())


def _root():
    h = _flux()
    return 200, {
        "name": SERVER_NAME,
        "user": _user(),
        "broker_version": h.attr_get("version"),
        "rank": int(h.attr_get("rank")),
        "size": int(h.attr_get("size")),
    }


def _health():
    return 200, {"status": "ok"}


ROUTES = {
    f"{_PREFIX}/": _root,
    f"{_PREFIX}/health": _health,
}


def _jobs_submit(body):
    """Submit a job from a structured JSON body (basic mode)."""
    command = body.get("command")
    if (
        not isinstance(command, list)
        or not command
        or not all(isinstance(c, str) for c in command)
    ):
        return 400, {"error": "'command' must be a non-empty list of strings"}

    # Pass every other field straight through as a from_command() kwarg.
    # None is filtered out so an unspecified/null field still falls back to
    # Flux's own default rather than overriding it with None explicitly
    # (e.g. num_tasks defaults to 1, not None). Anything JobspecV1 doesn't
    # recognize raises TypeError below, caught the same as other jobspec
    # errors -- no separate allowlist to keep in sync with from_command().
    kwargs = {k: v for k, v in body.items() if k != "command" and v is not None}

    # Without an explicit cwd/environment, from_command() would otherwise
    # inherit this server process's own -- not the submitting user's home
    # directory or a sane environment. Default both explicitly instead; an
    # explicit "cwd"/"environment" in the request still overrides this.
    pw = pwd.getpwuid(os.getuid())
    kwargs.setdefault("cwd", pw.pw_dir)
    kwargs.setdefault(
        "environment",
        {
            "HOME": pw.pw_dir,
            "USER": pw.pw_name,
            "LOGNAME": pw.pw_name,
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "SHELL": pw.pw_shell,
        },
    )

    try:
        jobspec = flux.job.JobspecV1.from_command(command, **kwargs)
    except (ValueError, TypeError) as err:
        return 400, {"error": f"invalid jobspec: {err}"}

    try:
        jobid = flux.job.submit(_flux(), jobspec)
    except OSError as err:
        # flux.job.submit() raises plain OSError for both "flux unreachable"
        # and "request rejected as invalid" (e.g. bad queue), distinguished
        # only by errno. EINVAL -> 400; anything else re-raises for
        # do_POST's existing OSError -> 503 handling.
        if err.errno == errno.EINVAL:
            return 400, {"error": str(err)}
        raise
    except (RuntimeError, ValueError) as err:
        return 400, {"error": str(err)}

    # 201 Created with a Location pointing at the new job resource, per the
    # usual convention for POST-to-collection. The id is echoed in the body
    # too for convenience; the two use the same representation.
    #
    # Use the F58 "plain" encoding (ASCII "f" prefix) rather than str(jobid),
    # whose default fancy prefix is U+0192 -- non-ASCII, so it would have to
    # be percent-encoded in the Location URL. JobID parses every encoding
    # (plain, fancy, decimal, ...) back to the same id, so input stays lenient.
    fluid = jobid.f58plain
    return 201, {"id": fluid}, {"Location": f"{_PREFIX}/jobs/{fluid}"}


POST_ROUTES = {
    f"{_PREFIX}/jobs": _jobs_submit,
}


def _parse_job_path(path):
    """Parse a bare /jobs/<id> from a request path.

    Returns the jobid, or None if path doesn't match this shape.
    Raises ValueError if the id portion isn't a valid Flux jobid.
    """
    prefix = f"{_PREFIX}/jobs/"
    if not path.startswith(prefix):
        return None
    jobid_str = path[len(prefix) :]
    if not jobid_str or "/" in jobid_str:
        return None
    return flux.job.JobID(jobid_str)  # raises ValueError if malformed


def _jobs_cancel(jobid, reason):
    """DELETE /api/v1/jobs/<id>: request cancellation of a job."""
    h = _flux()
    try:
        flux.job.cancel(h, jobid, reason=reason)
    except FileNotFoundError as err:
        # flux.job.cancel() raises this identical exception for a
        # nonexistent job and an already-inactive job. A genuinely
        # unreachable broker is already caught by _flux() above,
        # propagating to do_DELETE's OSError -> 503 handling.
        if "inactive" in str(err):
            return 409, {
                "error": f"job {jobid.f58plain} is already inactive, cannot cancel"
            }
        return 404, {"error": f"no such job: {jobid.f58plain}"}

    return 202, {"id": jobid.f58plain, "status": "cancel requested"}


DELETE_JOB_ROUTE = _jobs_cancel  # DELETE /jobs/<id>


class Handler(BaseHTTPRequestHandler):
    server_version = SERVER_NAME
    verbose = False

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        route = ROUTES.get(path)
        if route is None:
            self._send(404, {"error": "not found", "path": path})
            return
        try:
            status, body = route()
        except OSError as err:  # Flux not reachable
            status, body = 503, {"error": "flux unavailable", "detail": str(err)}
        except Exception as err:
            # Unanticipated bug: fail safely with a clean 500 instead of
            # letting BaseHTTPRequestHandler turn it into a raw traceback
            # on the wire or a dropped connection.
            self.log_error("unhandled exception in %s: %s", path, err)
            status, body = 500, {"error": "internal error"}
        self._send(status, body)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        route = POST_ROUTES.get(path)
        if route is None:
            self._send(404, {"error": "not found", "path": path})
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            if length < 0:
                # A negative length would make rfile.read(length) read until
                # EOF, hanging on a keep-alive connection. Reject it instead.
                self._send(400, {"error": "malformed request"})
                return
            if length > _MAX_BODY_SIZE:
                self._send(400, {"error": "request body too large"})
                return
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            self._send(400, {"error": "malformed request"})
            return
        if not isinstance(body, dict):
            self._send(400, {"error": "request body must be a JSON object"})
            return

        headers = None
        try:
            result = route(body)
            # A route returns (status, body) or (status, body, headers).
            status, resp = result[0], result[1]
            headers = result[2] if len(result) > 2 else None
        except OSError as err:  # Flux not reachable
            status, resp = 503, {"error": "flux unavailable", "detail": str(err)}
        except Exception as err:
            # Unanticipated bug: fail safely with a clean 500 instead of
            # letting BaseHTTPRequestHandler turn it into a raw traceback
            # on the wire or a dropped connection.
            self.log_error("unhandled exception in %s: %s", path, err)
            status, resp = 500, {"error": "internal error"}
        self._send(status, resp, headers)

    def do_DELETE(self):
        parsed = urllib.parse.urlsplit(self.path)
        # Accept any JobID()-parseable form on input (e.g. a job id
        # copied verbatim from `flux jobs` output, which defaults to the
        # non-ASCII "fancy" F58 form and would arrive percent-encoded) --
        # even though this server always emits the ASCII f58plain form
        # itself. Lenient on input, consistent on output.
        path = urllib.parse.unquote(parsed.path)
        reason = urllib.parse.parse_qs(parsed.query).get("reason", [None])[0]

        try:
            jobid = _parse_job_path(path)
        except ValueError as err:
            self._send(400, {"error": str(err)})
            return
        if jobid is None:
            self._send(404, {"error": "not found", "path": path})
            return

        try:
            result = DELETE_JOB_ROUTE(jobid, reason)
            status, resp = result[0], result[1]
            headers = result[2] if len(result) > 2 else None
        except OSError as err:  # Flux not reachable
            status, resp = 503, {"error": "flux unavailable", "detail": str(err)}
            headers = None
        except Exception as err:
            # Unanticipated bug: fail safely with a clean 500 instead of
            # letting BaseHTTPRequestHandler turn it into a raw traceback
            # on the wire or a dropped connection.
            self.log_error("unhandled exception in %s: %s", path, err)
            status, resp = 500, {"error": "internal error"}
            headers = None
        self._send(status, resp, headers)

    def _send(self, status, body, headers=None):
        data = (json.dumps(body) + "\n").encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(data)
        except BrokenPipeError:
            pass  # Client disconnected before reading response

    def address_string(self):
        ca = self.client_address
        return ca[0] if isinstance(ca, tuple) else "unix"

    def _log(self, stream, format, *args):
        # Flush: under `flux exec --bg` the stream is a block-buffered pipe.
        stream.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), format % args)
        )
        stream.flush()

    def log_message(self, format, *args):
        # Request telemetry -> stdout. Under `flux exec --bg` the subprocess
        # server logs stdout at LOG_INFO (vs stderr at LOG_ERR). Gated by
        # --verbose.
        if self.verbose:
            self._log(sys.stdout, format, *args)

    def log_error(self, format, *args):
        # Genuine errors -> stderr (LOG_ERR under flux exec --bg), always.
        self._log(sys.stderr, format, *args)


class _Server(HTTPServer):
    """HTTPServer that, on a unix socket, accepts connections only from a
    permitted uid, verified via SO_PEERCRED. This makes the access policy
    explicit in the application, independent of (and robust to a misconfigured)
    socket file mode. allowed_peer_uid is None for TCP, where peer credentials
    are unavailable, and the check is skipped.

    With idle_timeout set (seconds), serve() exits after that long with no new
    connection. Under socket activation systemd re-activates on the next one."""

    allowed_peer_uid = None
    idle_timeout = None
    _idle = False

    def handle_timeout(self):
        self._idle = True

    def serve(self):
        """Serve requests until interrupted, or (if idle_timeout is set) until
        idle_timeout seconds elapse with no new connection."""
        if self.idle_timeout is None:
            self.serve_forever()
            return
        self.timeout = self.idle_timeout
        while not self._idle:
            self.handle_request()
        sys.stderr.write(
            f"flux-rest-server: no connection for {self.idle_timeout}s, exiting\n"
        )

    def verify_request(self, request, client_address):
        if self.allowed_peer_uid is None:
            return True
        try:
            creds = request.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("iII")
            )
            _pid, uid, _gid = struct.unpack("iII", creds)
        except OSError:
            return False
        if uid != self.allowed_peer_uid:
            sys.stderr.write(
                f"flux-rest-server: rejected connection from uid {uid}; "
                f"only uid {self.allowed_peer_uid} may connect\n"
            )
            return False
        return True


def server_on_address(host, port):
    """Standalone/dev mode: bind and listen on host:port."""
    return _Server((host, port), Handler)


def server_on_socket(listen_sock):
    """Socket-activation mode: serve on an already-listening socket
    (e.g. one passed by systemd). Works for AF_INET or AF_UNIX."""
    srv = _Server(("", 0), Handler, bind_and_activate=False)
    try:
        srv.socket.close()
    except OSError:
        pass
    srv.address_family = listen_sock.family
    srv.socket = listen_sock
    srv.server_address = listen_sock.getsockname()
    return srv


_LISTEN_FDS_START = 3


def _socket_activated():
    return (
        os.environ.get("LISTEN_PID") == str(os.getpid())
        and int(os.environ.get("LISTEN_FDS", "0")) >= 1
    )


def server_on_unix_socket(socket_path):
    """Create server listening on a unix domain socket, restricted to the owner
    (mode 0600). The SO_PEERCRED check enforces the same policy independently."""
    # Remove stale socket if it exists
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(socket_path)
    os.chmod(socket_path, 0o600)
    sock.listen(5)
    return server_on_socket(sock)


def _fsd(value):
    """argparse type: a Flux standard duration (e.g. 30s, 5m) -> seconds."""
    try:
        return flux.util.parse_fsd(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc))


def main():
    parser = argparse.ArgumentParser(prog="flux-rest-server")
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="bind address when using --port (default 127.0.0.1)",
    )
    parser.add_argument(
        "--port", type=int, help="use TCP socket on PORT instead of default unix socket"
    )
    parser.add_argument(
        "--socket",
        metavar="PATH",
        help="listen on unix domain socket at PATH (default: rundir/rest)",
    )
    parser.add_argument(
        "--allow-user",
        metavar="USER",
        help="only permit this user to connect, verified via "
        "SO_PEERCRED (default: the invoking user)",
    )
    parser.add_argument(
        "--idle-timeout",
        type=_fsd,
        metavar="FSD",
        help="exit after this idle duration with no connection, "
        "e.g. 30s, 5m, 1h (default: run forever); under "
        "socket activation systemd re-activates on the next "
        "connection",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="log each request to stderr"
    )
    args = parser.parse_args()

    if args.idle_timeout is not None:
        if args.idle_timeout == float("inf"):
            args.idle_timeout = None  # "infinity": never time out
        elif args.idle_timeout <= 0:
            parser.error("--idle-timeout must be a positive duration")

    Handler.verbose = args.verbose

    if args.allow_user:
        try:
            allowed_uid = pwd.getpwnam(args.allow_user).pw_uid
        except KeyError:
            print(f"error: unknown user: {args.allow_user}", file=sys.stderr)
            sys.exit(1)
    else:
        allowed_uid = os.getuid()

    try:
        if _socket_activated():
            listen_sock = socket.socket(fileno=_LISTEN_FDS_START)
            srv = server_on_socket(listen_sock)
        elif args.port is not None:
            srv = server_on_address(args.host, args.port)
        else:
            # Self-created unix socket (default rundir/rest, or --socket PATH);
            # it is owner-only (0600), so a different allowed user could never
            # connect. For cross-user access use socket activation, where systemd
            # creates a group-accessible socket.
            if allowed_uid != os.getuid():
                print(
                    "error: --allow-user requires socket activation; a "
                    "self-created socket is owner-only",
                    file=sys.stderr,
                )
                sys.exit(1)
            # Default: unix socket in flux rundir
            if args.socket:
                socket_path = args.socket
            else:
                try:
                    h = _flux()
                    rundir = h.attr_get("rundir")
                    socket_path = os.path.join(rundir, "rest")
                except OSError as err:
                    print(f"error: cannot get flux rundir: {err}", file=sys.stderr)
                    print(
                        "hint: use --port for TCP mode outside a flux instance",
                        file=sys.stderr,
                    )
                    sys.exit(1)
            srv = server_on_unix_socket(socket_path)
    except OSError as err:
        if err.errno == 98:
            if args.port is not None:
                addr = f"{args.host}:{args.port}"
            else:
                addr = args.socket if args.socket else socket_path
            print(f"error: address {addr} already in use", file=sys.stderr)
        elif err.errno == 13:
            if args.port is not None:
                addr = f"{args.host}:{args.port}"
            else:
                addr = args.socket if args.socket else socket_path
            print(f"error: permission denied binding to {addr}", file=sys.stderr)
        else:
            print(f"error: failed to bind socket: {err}", file=sys.stderr)
        sys.exit(1)

    if srv.address_family == socket.AF_UNIX:
        srv.allowed_peer_uid = allowed_uid
    elif args.allow_user:
        print(
            "warning: --allow-user has no effect on a TCP socket "
            "(SO_PEERCRED unavailable)",
            file=sys.stderr,
        )

    srv.idle_timeout = args.idle_timeout

    try:
        srv.serve()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
