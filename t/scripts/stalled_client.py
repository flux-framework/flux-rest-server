#!/usr/bin/env python3
"""Check that a client which never sends a request cannot wedge the server.

Handler.timeout is what bounds this.  Without it, handle_one_request() blocks
in rfile.readline() forever and this single-threaded server never answers
anyone again -- silently, since nothing has gone wrong from its point of view.

Runs the server out of process with a short Handler.timeout, so the check takes
a second rather than the half minute the shipped value would need.

usage: stalled_client.py SERVER_PY SOCKET_PATH
"""

import importlib.util
import os
import signal
import socket
import sys
import time

TIMEOUT = 1.0  # Handler.timeout for this run
SLACK = 20.0  # give up well before the testsuite does
CONNECT_TRIES = 100
REQUEST = b"GET /api/v1/health HTTP/1.0\r\n\r\n"


def load(path):
    spec = importlib.util.spec_from_file_location("rest_server", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def serve(mod, sock_path):
    mod.Handler.timeout = TIMEOUT
    mod.server_on_unix_socket(sock_path).serve()


def connect(sock_path, timeout=SLACK):
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(timeout)
    sock.connect(sock_path)
    return sock


def request(sock_path):
    """One complete request; returns the raw response."""
    sock = connect(sock_path)
    try:
        sock.sendall(REQUEST)
        chunks = []
        while True:
            data = sock.recv(65536)
            if not data:
                return b"".join(chunks)
            chunks.append(data)
    finally:
        sock.close()


def wait_until_up(sock_path):
    for _ in range(CONNECT_TRIES):
        try:
            if b"200" in request(sock_path):
                return
        except OSError:
            pass
        time.sleep(0.1)
    raise SystemExit(f"server never came up on {sock_path}")


def main():
    server_py, sock_path = sys.argv[1], sys.argv[2]
    mod = load(server_py)

    # The shipped default is what protects a real server; serve() overrides it
    # below purely to keep this check quick, so assert it here or removing the
    # class attribute would leave this test passing on its own override.
    if mod.Handler.timeout is None:
        raise SystemExit("Handler.timeout is unset; a stalled client can wedge the server")

    pid = os.fork()
    if pid == 0:
        try:
            serve(mod, sock_path)
        except KeyboardInterrupt:
            pass
        finally:
            os._exit(0)

    try:
        wait_until_up(sock_path)

        # Connect and say nothing. The server is now parked in rfile.readline()
        # and, being single threaded, is answering no one.
        stalled = connect(sock_path)

        # A second client must still be served. On a serial server that means
        # "once the stalled connection times out", so this also measures that
        # the wait is bounded rather than forever.
        t0 = time.monotonic()
        try:
            body = request(sock_path)
        except socket.timeout:
            raise SystemExit(
                f"second client was never served: the stalled connection "
                f"wedged the server for at least {SLACK}s"
            )
        waited = time.monotonic() - t0
        if b"200" not in body:
            raise SystemExit(f"second client got: {body[:200]!r}")

        # And the stalled connection must have been dropped, not left open.
        stalled.settimeout(SLACK)
        try:
            if stalled.recv(4096) != b"":
                raise SystemExit("stalled connection got data, expected a close")
        except socket.timeout:
            raise SystemExit("stalled connection was never dropped")
        stalled.close()

        print(f"ok: stalled client dropped, second client served after {waited:.2f}s")
    finally:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)


main()
