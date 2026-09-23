#!/usr/bin/env python3
"""Check that SIGTERM/SIGINT does not truncate an in-flight response.

Loads flux-rest-server as a module, adds a deliberately slow route with a body
too large to be written in one go, and serves it from a child process.  The
parent then issues a request, signals the child while that request is in
flight, and checks the response still arrives whole.

Before issue #27 the signal handler raised KeyboardInterrupt from wherever the
main thread happened to be, which unwinds out of the request handler -- so the
client got a partial body, or none at all.

usage: stop_midrequest.py SERVER_PY SOCKET_PATH [SIGNAL]
"""

import importlib.util
import json
import os
import signal
import socket
import sys
import time

SLOW_PATH = "/api/v1/slow"
SLOW_DELAY = 1.0  # seconds the route stalls, so the signal lands inside it
PAD = 256 * 1024  # body padding, so a partial write is possible too
CONNECT_TRIES = 100
READ_TIMEOUT = 30


def load(path):
    spec = importlib.util.spec_from_file_location("rest_server", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def serve(mod, sock_path):
    """Child: serve the slow route until signalled. Does not return."""

    def slow():
        time.sleep(SLOW_DELAY)
        return 200, {"complete": True, "pad": "x" * PAD}

    mod.ROUTES[SLOW_PATH] = slow
    mod.server_on_unix_socket(sock_path).serve()


def connect(sock_path):
    for _ in range(CONNECT_TRIES):
        try:
            sock = socket.socket(socket.AF_UNIX)
            sock.connect(sock_path)
            return sock
        except OSError:
            sock.close()
            time.sleep(0.1)
    raise SystemExit(f"could not connect to {sock_path}")


def read_all(sock):
    sock.settimeout(READ_TIMEOUT)
    chunks = []
    while True:
        try:
            data = sock.recv(65536)
        except socket.timeout:
            raise SystemExit("timed out reading the response")
        if not data:
            return b"".join(chunks)
        chunks.append(data)


def check(raw):
    """Fail unless raw is a complete 200 with the whole body."""
    head, _, body = raw.partition(b"\r\n\r\n")
    if not _:
        raise SystemExit(f"truncated before end of headers: {raw[:200]!r}")
    status = head.split(b"\r\n", 1)[0]
    if b"200" not in status:
        raise SystemExit(f"unexpected status: {status!r}")

    length = None
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.lower() == b"content-length":
            length = int(value)
    if length is None:
        raise SystemExit("no Content-Length in response")
    if len(body) != length:
        raise SystemExit(f"truncated body: got {len(body)} of {length} bytes")
    if not json.loads(body).get("complete"):
        raise SystemExit("body did not round-trip")


def main():
    server_py, sock_path = sys.argv[1], sys.argv[2]
    signum = int(sys.argv[3]) if len(sys.argv) > 3 else signal.SIGTERM
    mod = load(server_py)

    pid = os.fork()
    if pid == 0:
        try:
            serve(mod, sock_path)
        except KeyboardInterrupt:
            pass
        finally:
            os._exit(0)

    try:
        sock = connect(sock_path)
        sock.sendall(f"GET {SLOW_PATH} HTTP/1.0\r\n\r\n".encode())
        time.sleep(SLOW_DELAY / 2)  # the route is now stalled
        os.kill(pid, signum)
        check(read_all(sock))
    finally:
        _, status = os.waitpid(pid, 0)

    if status != 0:
        raise SystemExit(f"server exited with wait status {status}")
    print("ok: response arrived intact")


main()
