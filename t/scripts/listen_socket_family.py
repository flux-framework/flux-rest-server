#!/usr/bin/env python3
"""Check that _listen_socket() preserves an inherited socket's address family.

socket.socket(fileno=fd) only infers the family from SO_DOMAIN on Python 3.7+;
on 3.6 it assumes AF_INET.  flux-rest-server enables its SO_PEERCRED check only
for AF_UNIX, so getting this wrong on a systemd-provided unix socket disables
the uid check entirely and serves any local user.

Creates a listening socket of each family, hands the fd to _listen_socket() the
way socket activation does, and checks the family survives.  Prints the failing
cases and exits nonzero.
"""

import importlib.util
import os
import socket
import sys
import tempfile

server_py = sys.argv[1]

spec = importlib.util.spec_from_file_location("flux_rest_server", server_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

failures = []


def check(name, sock, expected):
    # _listen_socket() takes ownership of the fd it is given, as it does with
    # the one systemd passes, so hand it a dup and keep ours for cleanup.
    wrapped = mod._listen_socket(os.dup(sock.fileno()))
    try:
        if wrapped.family != expected:
            failures.append(f"{name}: got {wrapped.family!r}, want {expected!r}")
    finally:
        wrapped.close()


tmpdir = tempfile.mkdtemp()
unix_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
unix_sock.bind(os.path.join(tmpdir, "s"))
unix_sock.listen(1)
check("AF_UNIX", unix_sock, socket.AF_UNIX)
unix_sock.close()

inet_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
inet_sock.bind(("127.0.0.1", 0))
inet_sock.listen(1)
check("AF_INET", inet_sock, socket.AF_INET)
inet_sock.close()

if failures:
    for line in failures:
        print(line, file=sys.stderr)
    sys.exit(1)
