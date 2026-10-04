#!/usr/bin/env python3
"""Drive the installer menu in a pseudo-terminal, the way a person would.

Usage: vm-menu-driver.py <log-file> <installer> <step>...

Each step is either "expect:<seconds>:<regular expression>", which waits for
the installer to print text matching the expression, or "send:<text>", which
types the text followed by Enter. Everything the installer prints is appended
to the log file. Each matched step is reported on the serial console, so the
VM test sees progress during long downloads and installations.
"""
import codecs
import os
import pty
import re
import select
import sys
import time


def console(message):
    try:
        with open("/dev/ttyS0", "w", encoding="utf-8") as serial:
            serial.write(message + "\n")
    except OSError:
        pass


def main():
    log_path, installer, *steps = sys.argv[1:]
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", installer])
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    pending = ""
    with open(log_path, "a", encoding="utf-8") as log:
        for number, step in enumerate(steps, 1):
            kind, _, rest = step.partition(":")
            if kind == "send":
                os.write(terminal, (rest + "\n").encode())
                continue
            if kind != "expect":
                raise SystemExit(f"unknown step: {step}")
            seconds, _, pattern = rest.partition(":")
            expression = re.compile(pattern)
            deadline = time.monotonic() + int(seconds)
            while True:
                found = expression.search(pending)
                if found:
                    pending = pending[found.end():]
                    console(f"VM_PHASE: {time.strftime('%H:%M:%S', time.gmtime())} menu step {number}: {pattern}")
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SystemExit(f"menu step {number}: no {pattern!r} within {seconds} seconds")
                ready, _, _ = select.select([terminal], [], [], min(remaining, 5))
                if not ready:
                    continue
                try:
                    data = os.read(terminal, 65536)
                except OSError:
                    data = b""
                if not data:
                    raise SystemExit(f"menu step {number}: the installer exited before {pattern!r}")
                text = decoder.decode(data)
                log.write(text)
                log.flush()
                pending += text
        # Let the installer act on the last answer, such as a reboot, before
        # the terminal goes away under it.
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], 5)
            if not ready:
                continue
            try:
                data = os.read(terminal, 65536)
            except OSError:
                data = b""
            if not data:
                break
            log.write(decoder.decode(data))
            log.flush()
    _, status = os.waitpid(pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else 0)


if __name__ == "__main__":
    main()
