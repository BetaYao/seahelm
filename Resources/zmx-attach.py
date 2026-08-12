#!/usr/bin/env python3
"""Relay a zmx session's *raw* VT stream on stdout, by being a real attach client.

Why this exists: `zmx tail` and `zmx history --vt` are linearized. They keep SGR
colour but drop every cursor-motion sequence, so a TUI that repaints in place
(Codex, Claude Code) arrives as N stacked copies of its frame instead of one
frame redrawn N times. `zmx attach` is the client path Seahelm itself renders
through, and it preserves the motion — measured side by side on the same
workload: attach 5 cursor-ups, tail 0.

Node has no built-in pty and attach needs a controlling terminal, so this stands
in as the pty. stdout carries PTY output; stdin is written back into the PTY, so
the same channel can carry keystrokes.

    zmx-attach.py <session> <rows> <cols>

Two things here are load-bearing rather than incidental:
  * ZMX_SESSION is scrubbed from the child. Inherited from a Seahelm pane it
    hijacks attach onto *that* session and the stream comes back silently empty.
  * The window size is set on the slave fd before exec. Attaching is not
    read-only — a client whose size differs can resize the session and reflow
    what the Mac is showing. We pass the session's own measured size in.
"""
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios

ZMX = os.environ.get('ZMX') or 'zmx'


def main() -> int:
    if len(sys.argv) < 2:
        print('usage: zmx-attach.py <session> [rows] [cols]', file=sys.stderr)
        return 2
    session = sys.argv[1]
    rows = int(sys.argv[2]) if len(sys.argv) > 2 else 24
    cols = int(sys.argv[3]) if len(sys.argv) > 3 else 80

    master, slave = pty.openpty()
    # Size the tty before the child can look at it, so attach never resizes the
    # session out from under the Mac.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    pid = os.fork()
    if pid == 0:
        os.setsid()
        try:
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except OSError:
            pass
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        if master > 2:
            os.close(master)
        if slave > 2:
            os.close(slave)
        env = dict(os.environ)
        env.pop('ZMX_SESSION', None)          # see module docstring
        env['TERM'] = env.get('TERM') or 'xterm-256color'
        try:
            os.execvpe(ZMX, [ZMX, 'attach', session], env)
        except OSError:
            os._exit(127)
    os.close(slave)

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    open_fds = [master, stdin_fd]

    def shutdown(*_):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    signal.signal(signal.SIGTERM, lambda *a: (shutdown(), sys.exit(0)))
    signal.signal(signal.SIGINT, lambda *a: (shutdown(), sys.exit(0)))

    while True:
        try:
            readable, _, _ = select.select(open_fds, [], [], 0.5)
        except InterruptedError:
            continue
        except OSError as e:
            if e.errno == errno.EBADF:
                break
            raise

        if master in readable:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            os.write(stdout_fd, data)

        if stdin_fd in readable:
            try:
                keys = os.read(stdin_fd, 65536)
            except OSError:
                keys = b''
            if keys:
                os.write(master, keys)
            else:
                open_fds = [master]          # stdin closed; keep relaying output

        done, _ = os.waitpid(pid, os.WNOHANG)
        if done:
            # Drain whatever the client emitted on its way out.
            try:
                while True:
                    tail = os.read(master, 65536)
                    if not tail:
                        break
                    os.write(stdout_fd, tail)
            except OSError:
                pass
            break

    shutdown()
    return 0


if __name__ == '__main__':
    sys.exit(main())
