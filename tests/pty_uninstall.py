"""Run a command with or without a controlling terminal and answer its question.

usage: [PTY_PROMPT=text] pty_uninstall.py <answer|none> <command> [args...]
  answer   text typed at the terminal (for example yes or no)
  none     run in a new session with no terminal at all, so /dev/tty cannot be opened
Prints the command's output, then a last line: exit=<status>
"""
import os
import pty
import subprocess
import sys

PROMPT = os.environ.get("PTY_PROMPT", "Type yes to continue").encode()
answer = sys.argv[1]
command = sys.argv[2:]

if answer == "none":
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
    sys.stdout.write(result.stdout.decode("utf-8", "replace"))
    print("exit=%d" % result.returncode)
    sys.exit(0)

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
output = b""
sent = False
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk
    if not sent and PROMPT in output:
        os.write(fd, (answer + "\n").encode())
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(output.decode("utf-8", "replace").replace("\r", ""))
print("exit=%d" % (os.waitstatus_to_exitcode(status)))
