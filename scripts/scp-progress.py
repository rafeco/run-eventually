#!/usr/bin/python3
"""Run batch SCP with its terminal progress meter captured as readable log lines.

Usage: python3 scripts/scp-progress.py [scp arguments...]
Only stdout gets a terminal; stdin stays closed and stderr stays separate.
The terminal requires a separate session, so relay cancellation to that session's
process group and force cleanup within the scheduler's one-second grace period.
"""
import codecs
import errno
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


class ProgressLines:
    def __init__(self, emit):
        self.emit = emit
        self.buffer = ""
        self.last_progress = None

    def line(self, text):
        text = text.strip()
        if not text:
            return
        # ETA/speed changes alone are not evidence that bytes moved. Avoid
        # refreshing the app's last-output clock indefinitely on a stalled meter.
        match = re.match(r"^(.*?)\s+(\d+)%\s+(\d+\w*)\s+", text)
        if match:
            key = (*match.groups(), "stalled" in text)
            if key == self.last_progress:
                return
            self.last_progress = key
        else:
            self.last_progress = None
        self.emit(text)

    def feed(self, text, final=False):
        self.buffer += text
        parts = re.split(r"[\r\n]", self.buffer)
        self.buffer = parts.pop()
        for part in parts:
            self.line(part)
        if final:
            self.line(self.buffer)
            self.buffer = ""


def run(command):
    stop_signal = None

    def request_stop(signum, _frame):
        nonlocal stop_signal
        stop_signal = signum

    signals = (signal.SIGTERM, signal.SIGINT)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    old_handlers = {s: signal.signal(s, request_stop) for s in signals}
    saved_stderr = os.dup(2)
    try:
        pid, terminal = pty.fork()
    except BaseException:
        os.close(saved_stderr)
        for s, handler in old_handlers.items():
            signal.signal(s, handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        raise
    if pid == 0:
        for s in signals:
            signal.signal(s, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        try:
            os.dup2(saved_stderr, 2)
            os.close(saved_stderr)
            with open(os.devnull, "rb") as null:
                os.dup2(null.fileno(), 0)
            os.execvp(command[0], command)
        except BaseException as error:
            os.write(2, (str(error) + "\n").encode())
            os._exit(127)

    os.close(saved_stderr)
    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    lines = ProgressLines(lambda line: print(line, flush=True))
    status = None
    stopping_at = None

    def signal_child(signum):
        try:
            os.killpg(pid, signum)
        except ProcessLookupError:
            # Child may not have established its terminal session yet.
            if status is None:
                try:
                    os.kill(pid, signum)
                except ProcessLookupError:
                    pass

    try:
        fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 160, 0, 0))
        while True:
            if stop_signal is not None:
                if stopping_at is None:
                    stopping_at = time.monotonic()
                    signal_child(stop_signal)
                if time.monotonic() - stopping_at >= 0.3:
                    signal_child(signal.SIGKILL)
                    break
            if status is None:
                waited, result = os.waitpid(pid, os.WNOHANG)
                if waited:
                    status = result
            if select.select([terminal], [], [], 0.05)[0]:
                try:
                    chunk = os.read(terminal, 8192)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if not chunk:
                    if stop_signal is None:
                        break
                else:
                    lines.feed(decoder.decode(chunk))
        lines.feed(decoder.decode(b"", final=True), final=True)
        if status is None:
            _, status = os.waitpid(pid, 0)
        return 128 + stop_signal if stop_signal else os.waitstatus_to_exitcode(status)
    finally:
        # Also clean up if the log destination closes or decoding/reading fails.
        signal_child(signal.SIGKILL)
        if status is None:
            os.waitpid(pid, 0)
        os.close(terminal)
        for s, handler in old_handlers.items():
            signal.signal(s, handler)


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: scp-progress.py [scp arguments...]")
    print("SCP: connecting; transfer progress will appear below.", flush=True)
    code = run(["/usr/bin/scp", "-B", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                *sys.argv[1:]])
    print(f"SCP: {'completed' if code == 0 else 'exited with status ' + str(code)}.", flush=True)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
