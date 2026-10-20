#!/usr/bin/env python3
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LINE1 = re.compile(rb"\x1b\[38;5;\d+m(?:[^\n]*?)Claude")
START = b"\x1b[38;5;174m"
CSI = re.compile(rb"\x1b\[[0-9;?<>=!]*[ -/]*[@-~]")


def visible(data: bytes) -> bytes:
    return CSI.sub(b"", data).replace(b" ", b"").lower()


def main() -> int:
    binary = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, "qc")
    cwd = sys.argv[2] if len(sys.argv) > 2 else ROOT
    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env.pop("QUIETCLAUDE_CLAUDE_PATH", None)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execve(binary, [binary], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    os.kill(pid, signal.SIGWINCH)

    output = b""
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output += chunk

    for _ in range(2):
        try:
            os.write(fd, b"\x03")
        except OSError:
            pass
        time.sleep(0.3)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    os.close(fd)

    raw_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "qc-pty-check.bin")
    with open(raw_path, "wb") as fh:
        fh.write(output)

    text = visible(output)
    trust = b"accessingworkspace" in text or b"quicksafetycheck" in text
    banner_lines = [line for line in output.split(b"\n") if line.startswith(START) and LINE1.search(line)]
    notice = b"Transcript" in output or b"Try" in output
    print(f"cwd: {cwd}")
    print(f"captured {len(output)} bytes (saved to {raw_path})")
    removed = output.count(b"[quietclaude] removed banner")
    if removed:
        print(f"debug reports: {removed} removal(s)")
    print(f"trust prompt shown: {trust}")
    print(f"banner line1 present: {bool(banner_lines)}")
    print(f"notice text present: {notice}")
    if trust:
        print("RESULT: trust prompt appeared instead of the banner; accept it manually and rerun")
        return 2
    ok = not banner_lines and notice
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
