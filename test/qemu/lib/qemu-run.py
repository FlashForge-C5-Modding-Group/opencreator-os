#!/usr/bin/env python3
"""Run one QEMU boot and drive its serial console from a step file.

    qemu-run.py --log LOG --results RES --steps STEPS [--timeout S] -- QEMU ARGV...

QEMU must be started with "-serial stdio" (and "-monitor none -display
none"); its stdout is the serial console, appended to LOG. Steps (one per
line, '#' comments):

  expect SECONDS REGEX      wait for REGEX (Python re, MULTILINE) in console
                            output received after the previous match
  absent REGEX              fail if REGEX ever matched the whole log so far
  shell SECONDS             get an OpenWrt root shell on the console (press
                            Enter, log in if asked) and switch it to a quiet
                            command channel (read loop | sh: no prompt, no printk)
  run SECONDS NAME CMD...   run CMD in that shell; output and exit status go
                            to RES as "== NAME rc=N" followed by the output
  send TEXT                 send TEXT + newline
  sleep SECONDS
  kill-when SECONDS REGEX   wait for REGEX, then SIGKILL QEMU (power cut)
  kill                      SIGKILL QEMU now
  wait-exit SECONDS         wait for QEMU to exit by itself (reboot/power-off
                            with -no-reboot)

Exit status: 0 all steps passed, 3 a step failed (reason on stderr and in
RES as "== FAIL ..."), 4 QEMU could not be started.
"""
import argparse
import os
import re
import select
import signal
import subprocess
import sys
import time

PASSWORD = os.environ.get("QEMU_ROOT_PASSWORD", "FlashForge2026")


class Console:
    def __init__(self, argv, log_path, results_path, total_timeout):
        self.log = open(log_path, "ab", buffering=0)
        self.results = open(results_path, "a", encoding="utf-8")
        self.buf = ""          # whole decoded console output
        self.pos = 0           # expect() searches from here
        self.deadline = time.monotonic() + total_timeout
        try:
            self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, bufsize=0)
        except OSError as e:
            print(f"qemu-run: cannot start QEMU: {e}", file=sys.stderr)
            sys.exit(4)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.n_run = 0

    def _pump(self, wait):
        """Read available output (waiting up to `wait` s). False on EOF."""
        fd = self.proc.stdout.fileno()
        r, _, _ = select.select([fd], [], [], wait)
        if not r:
            return True
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            return True
        if not data:
            return False
        self.log.write(data.replace(b"\r", b""))
        self.buf += data.decode("utf-8", "replace").replace("\r", "")
        return True

    def alive(self):
        return self.proc.poll() is None

    def expect(self, regex, timeout):
        rx = re.compile(regex, re.MULTILINE)
        end = min(time.monotonic() + timeout, self.deadline)
        while True:
            m = rx.search(self.buf, self.pos)
            if m:
                self.pos = m.end()
                return m
            left = end - time.monotonic()
            if left <= 0:
                return None
            if not self._pump(min(left, 0.5)) and not self.alive():
                # drain, then one last search
                while self._pump(0):
                    pass
                m = rx.search(self.buf, self.pos)
                if m:
                    self.pos = m.end()
                return m

    def send(self, text):
        if not self.alive():
            return False
        try:
            self.proc.stdin.write(text.encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            return False
        return True

    def shell(self, timeout):
        end = time.monotonic() + timeout
        if not self.expect(r"Please press Enter to activate this console", timeout):
            return "no console activation prompt"
        self.send("\n")
        rx = r"(login: *$|Password: *$|[#\$] *$)"
        while time.monotonic() < end:
            m = self.expect(rx, end - time.monotonic())
            if not m:
                break
            if m.group(0).startswith("login"):
                self.send("root\n")
            elif m.group(0).startswith("Password"):
                self.send(PASSWORD + "\n")
            else:
                break
        else:
            return "no shell prompt"
        # quiet command channel: no prompt, no line editing, no printk on the
        # console. OpenWrt's busybox has no stty, so the tty still echoes
        # input; run() markers are built so that echoed lines never match.
        # Input typed ahead of the exec would be swallowed by ash's line
        # editor and lost, so ping until the new channel answers. The channel
        # runs its input in order: answers to earlier pings all come before
        # the output of any later command.
        # (busybox cat holds tty input back - it copies with sendfile - so a
        # shell read loop feeds the pipe line by line)
        self.send("dmesg -n 1; exec sh -c 'while IFS= read -r l; do printf \"%s\\n\" \"$l\"; done | sh 2>&1'\n")
        for _ in range(60):
            self.send("echo __SHELL_READY__\n")
            if self.expect(r"^__SHELL_READY__$", 0.5):
                return None
        return "command channel did not come up"

    def run(self, name, cmd, timeout):
        self.n_run += 1
        tag = f"{self.n_run}_{re.sub(r'[^A-Za-z0-9_]', '_', name)}"
        self.send(f"echo __B_{tag}__; {{ {cmd}\n}} 2>&1; echo __E_{tag}_$?__\n")
        if not self.expect(rf"^__B_{tag}__$", 30):
            return None, "command start marker not seen"
        start = self.pos
        m = self.expect(rf"__E_{tag}_(\d+)__$", timeout)
        if not m:
            return None, "command did not finish"
        out = self.buf[start:m.start()].lstrip("\n")
        out = "".join(l for l in out.splitlines(True)
                      if not l.startswith("} 2>&1; echo __E_") and f"echo __B_{tag}__" not in l)
        return (int(m.group(1)), out), None

    def kill(self):
        if self.alive():
            self.proc.send_signal(signal.SIGKILL)
            self.proc.wait()

    def wait_exit(self, timeout):
        end = min(time.monotonic() + timeout, self.deadline)
        while self.alive() and time.monotonic() < end:
            self._pump(0.5)
        # drain to EOF only once QEMU is gone: while it runs, _pump(0)
        # returns True with nothing to read and this would never end
        if self.alive():
            return False
        while self._pump(0):
            pass
        return True

    def result(self, text):
        self.results.write(text)
        self.results.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--results", required=True)
    ap.add_argument("--steps", required=True)
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("qemu", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    argv = a.qemu[1:] if a.qemu and a.qemu[0] == "--" else a.qemu
    with open(a.steps, encoding="utf-8") as f:
        steps = [l.rstrip("\n") for l in f if l.strip() and not l.lstrip().startswith("#")]

    c = Console(argv, a.log, a.results, a.timeout)
    rc = 0
    for step in steps:
        verb, _, rest = step.strip().partition(" ")
        err = None
        if verb == "expect":
            secs, _, rx = rest.partition(" ")
            if not c.expect(rx, float(secs)):
                err = f"timeout after {secs}s waiting for /{rx}/"
        elif verb == "absent":
            if re.search(rest, c.buf, re.MULTILINE):
                err = f"unexpected /{rest}/ in console output"
        elif verb == "shell":
            err = c.shell(float(rest))
        elif verb == "run":
            secs, name, cmd = rest.split(" ", 2)
            res, err = c.run(name, cmd, float(secs))
            if res:
                code, out = res
                c.result(f"== {name} rc={code}\n{out}")
                if not out.endswith("\n") and out:
                    c.result("\n")
            else:
                err = f"run {name}: {err}"
        elif verb == "send":
            c.send(rest + "\n")
        elif verb == "sleep":
            end = time.monotonic() + float(rest)
            while time.monotonic() < end:
                c._pump(min(0.5, end - time.monotonic()))
        elif verb == "kill-when":
            secs, _, rx = rest.partition(" ")
            if c.expect(rx, float(secs)):
                c.kill()
            else:
                err = f"timeout after {secs}s waiting for /{rx}/ (kill-when)"
        elif verb == "kill":
            c.kill()
        elif verb == "wait-exit":
            if not c.wait_exit(float(rest)):
                err = f"QEMU still running after {rest}s"
        else:
            err = f"unknown step '{verb}'"
        if err:
            c.result(f"== FAIL {step}\n{err}\n")
            print(f"qemu-run: step failed: {step}: {err}", file=sys.stderr)
            rc = 3
            break
    c.kill()
    while c._pump(0):
        pass
    sys.exit(rc)


if __name__ == "__main__":
    main()
