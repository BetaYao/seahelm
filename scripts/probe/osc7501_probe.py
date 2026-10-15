#!/usr/bin/env python3
"""Stand in as an OSC 7501-capable terminal and record what an agent reports.

Seahelm's GhosttyKit does not answer the OSC 7501 support query yet, and Claude
Code only reports program status once that query is answered — so the only way
to see what it would send is a terminal that answers. This is that terminal: a
pty that replies to the probes an agent TUI sends at startup (7501, DA1/DA2,
XTVERSION, kitty keyboard, DECRQM, OSC 10/11, CPR) and logs every OSC 7501
sequence with its keys decoded. See docs/osc7501.md.

    osc7501_probe.py [--zmx SESSION] [--no-reply] [--timeout S] -- CMD...

  --zmx SESSION  run CMD inside `zmx attach SESSION`, so the query and its reply
                 cross zmx the way they do in a Seahelm pane
  --no-reply     do not answer the 7501 query (baseline: expect no reports)

It drives a Claude Code session: accept the folder-trust
dialog, ask for one Bash call, approve the permission prompt, wait for the turn
to finish, exit. Seahelm/zmx env is scrubbed from the child so its hooks cannot
report into the live app.
"""
import argparse
import base64
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

ESC = b'\x1b'
ST = rb'(?:\x1b\\|\x07)'
OSC_7501 = re.compile(rb'\x1b\]7501;([^\x07\x1b]*)' + ST)
QUERIES = [
    # (name, pattern, reply) — replied to in the order they appear in the stream.
    ('osc7501?', re.compile(rb'\x1b\]7501;\?' + ST), b'\x1b]7501;?\x1b\\'),
    ('da1', re.compile(rb'\x1b\[0?c'), b'\x1b[?62;22c'),
    ('da2', re.compile(rb'\x1b\[>0?c'), b'\x1b[>1;10;0c'),
    ('xtversion', re.compile(rb'\x1b\[>0?q'), b'\x1bP>|osc7501-probe 1.0\x1b\\'),
    ('kitty-kb', re.compile(rb'\x1b\[\?u'), b'\x1b[?0u'),
    ('decrqm', re.compile(rb'\x1b\[\?(\d+)\$p'), None),
    ('osc10', re.compile(rb'\x1b\]10;\?' + ST), b'\x1b]10;rgb:cdcd/d6d6/f4f4\x1b\\'),
    ('osc11', re.compile(rb'\x1b\]11;\?' + ST), b'\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\'),
    ('cpr', re.compile(rb'\x1b\[6n'), b'\x1b[1;1R'),
]
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*' + ST + rb'|\x1bP[^\x1b]*\x1b\\|\x1b.')
SCRUB = ('SEAHELM_', 'ZMX_', 'TMUX', 'TERM_PROGRAM', 'CLAUDE')


def decode_report(body: bytes) -> dict:
    out = {}
    for pair in body.decode('ascii', 'replace').split(':'):
        if '=' not in pair:
            out.setdefault('_flags', []).append(pair.strip())
            continue
        k, v = pair.split('=', 1)
        k, v = k.strip(), v.strip()
        if k in ('msg', 'title'):
            try:
                v = base64.b64decode(v + '=' * (-len(v) % 4)).decode('utf-8')
            except Exception:
                v = f'<bad base64 {v!r}>'
        out[k] = v
    return out


class Term:
    def __init__(self, argv, reply_7501, log):
        self.t0 = time.monotonic()
        self.reply_7501 = reply_7501
        self.log = log
        self.pending = b''   # undigested tail that may hold a split sequence
        self.screen = b''    # recent output, ANSI-stripped, for expect()
        self.reports = []
        self.queries = []
        env = {k: v for k, v in os.environ.items() if not k.startswith(SCRUB)}
        env['TERM'] = 'xterm-256color'
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))

    def now(self):
        return time.monotonic() - self.t0

    def note(self, msg):
        line = f'[{self.now():7.2f}] {msg}'
        print(line, flush=True)
        self.log.write(line + '\n')

    def snapshot(self, label):
        text = re.sub(rb'\s+', b' ', self.screen[-1500:]).decode('utf-8', 'replace')
        self.log.write(f'--- screen @{self.now():.2f} {label}: {text}\n')

    def send(self, data: bytes, why=''):
        self.snapshot(f'before {why or data!r}')
        self.note(f'>> {why or data!r}')
        os.write(self.fd, data)

    def _digest(self, chunk: bytes):
        buf = self.pending + chunk
        events = []
        for m in OSC_7501.finditer(buf):
            if m.group(1) != b'?':
                events.append((m.start(), 'report', m.group(1)))
        for name, pat, reply in QUERIES:
            for m in pat.finditer(buf):
                events.append((m.start(), name, m))
        for _, kind, val in sorted(events, key=lambda e: e[0]):
            if kind == 'report':
                rec = decode_report(val)
                self.reports.append((self.now(), rec))
                self.note(f'7501 {rec}')
                continue
            self.queries.append(kind)
            if kind == 'osc7501?':
                self.note('query OSC 7501 ; ?' + ('' if self.reply_7501 else '  (not answering)'))
                if not self.reply_7501:
                    continue
            reply = dict((n, r) for n, _, r in QUERIES)[kind]
            if kind == 'decrqm':
                reply = b'\x1b[?' + val.group(1) + b';2$y'
            os.write(self.fd, reply)
        # Keep a short tail so a sequence split across reads is seen next time,
        # but never re-digest a complete one (the tail starts after the last ESC
        # only if that ESC is unterminated).
        last = buf.rfind(ESC)
        tail = buf[last:] if last >= 0 and len(buf) - last < 4096 else b''
        if tail and (OSC_7501.match(tail) or any(p.match(tail) for _, p, _ in QUERIES)):
            tail = b''
        self.pending = tail
        self.screen = (self.screen + ANSI.sub(b'', chunk))[-20000:]

    def pump(self, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            self._digest(chunk)
        return True

    def expect(self, needle: str, timeout):
        """Wait until `needle` (case-insensitive) shows in output since the last call."""
        self.screen = b''
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if needle.lower().encode() in self.screen.lower():
                return True
            if not self.pump(0.2):
                return False
        return False

    def wait_report(self, pred, timeout):
        seen = len(self.reports)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if any(pred(r) for _, r in self.reports[seen:]):
                return True
            if not self.pump(0.2):
                return False
        return False


def drive_claude(t: Term, timeout):
    t.pump(6)
    if b'trust' in t.screen.lower():
        t.send(b'\r', 'accept folder trust')
        t.pump(4)
    t.send(b'Use the Bash tool to run exactly: touch osc7501-probe.txt', 'type prompt')
    t.pump(1)
    t.send(b'\r', 'submit')
    if t.expect('proceed', timeout):
        t.pump(2)
        t.send(b'\r', 'approve permission')
    else:
        t.note('no permission prompt seen')
    if not t.wait_report(lambda r: r.get('state') in ('idle', 'done', 'error'), timeout):
        t.note('no idle/done report after the turn')
    t.pump(3)
    t.send(b'\x03', 'ctrl-c')
    t.pump(1)
    t.send(b'\x03', 'ctrl-c')
    t.pump(4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--zmx', metavar='SESSION')
    ap.add_argument('--zmx-bin', default=os.environ.get('ZMX', 'zmx'))
    ap.add_argument('--no-reply', action='store_true')
    ap.add_argument('--timeout', type=float, default=90)
    ap.add_argument('--log', default='osc7501-probe.log')
    ap.add_argument('cmd', nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ['--'] else a.cmd
    if not cmd and not a.zmx:
        ap.error('missing CMD (only --zmx may omit it, to attach to an existing session)')
    argv = [a.zmx_bin, 'attach', a.zmx, *cmd] if a.zmx else cmd

    with open(a.log, 'w') as log:
        t = Term(argv, not a.no_reply, log)
        t.note(f'spawn {argv}')
        try:
            drive_claude(t, a.timeout)
        finally:
            try:
                os.kill(t.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        t.note(f'queries seen: {sorted(set(t.queries))}')
        t.note(f'{len(t.reports)} OSC 7501 reports')
        for at, rec in t.reports:
            t.note(f'  {at:7.2f}  {rec}')


if __name__ == '__main__':
    main()
