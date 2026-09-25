#!/Library/Frameworks/Python.framework/Versions/3.10/bin/python3.10
# platform: macOS-only -- stands between lldb and Apple's 10.9 debugserver
"""
debugserver shim for the macOS 10.9 toolchain.

A modern lldb (22) launches debugserver with a pre-connected socket via
`--fd=N`.  The only debugserver that builds/runs on a 10.9 kernel is Apple's
Command Line Tools debugserver (debugserver 22.1.1 needs a >=10.12 SDK to even
compile -- compression.h, task_read_t, ... -- so it is built with
LLDB_USE_SYSTEM_DEBUGSERVER=ON).  That ~2013 debugserver predates `--fd`; it
only knows the `host:port` listen model (and reverse-connect / unix-socket).

This shim bridges the two: when lldb passes `--fd=N`, it launches the real
debugserver listening on a private loopback port (forwarding the flags the old
one understands -- e.g. --native-regs, --setsid), connects to it, and relays
bytes between lldb's socket (fd N) and that connection.  The launch/attach
request flows as ordinary gdb-remote packets through the relay, so `run`,
`attach`, breakpoints, stepping, registers, etc. all work.  Any other
invocation (manual `host:port`, reverse-connect, unix-socket) is exec'd through
to the real debugserver unchanged.

The 12-year protocol gap is otherwise compatible for x86_64: lldb falls back to
its built-in register layout (the old debugserver lacks qXfer:features:read).
"""
import os
import select
import signal
import socket
import subprocess
import sys
import time

# Apple's CLT debugserver (already code-signed with debug entitlements on 10.9).
REAL_DEBUGSERVER = (
    "/Library/Developer/CommandLineTools/Library/PrivateFrameworks/"
    "LLDB.framework/Versions/A/Resources/debugserver"
)


def main():
    args = sys.argv[1:]
    fd = None
    passthrough = []
    skip_next = False
    for i, a in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if a.startswith("--fd="):
            fd = int(a.split("=", 1)[1])
        elif a == "--fd":
            fd = int(args[i + 1])
            skip_next = True
        else:
            passthrough.append(a)

    # No socket handoff -> the old debugserver handles this invocation directly.
    if fd is None:
        os.execv(REAL_DEBUGSERVER, [REAL_DEBUGSERVER] + args)

    # Socket-handoff mode: run the real debugserver as a loopback listener and relay.
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()

    ds = subprocess.Popen(
        [REAL_DEBUGSERVER] + passthrough + ["127.0.0.1:%d" % port]
    )

    conn = None
    deadline = time.time() + 5.0
    while time.time() < deadline and ds.poll() is None:
        try:
            conn = socket.create_connection(("127.0.0.1", port), timeout=1.0)
            break
        except OSError:
            time.sleep(0.05)
    if conn is None:
        try:
            ds.kill()
        except OSError:
            pass
        sys.exit(1)

    conn.setblocking(True)
    conn_fd = conn.fileno()
    fds = [fd, conn_fd]
    try:
        while True:
            readable, _, _ = select.select(fds, [], [])
            if fd in readable:
                data = os.read(fd, 65536)
                if not data:
                    break
                os.write(conn_fd, data)
            if conn_fd in readable:
                data = os.read(conn_fd, 65536)
                if not data:
                    break
                os.write(fd, data)
    finally:
        if ds.poll() is None:
            try:
                ds.send_signal(signal.SIGTERM)
            except OSError:
                pass


if __name__ == "__main__":
    main()
