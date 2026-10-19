#!/usr/bin/python3
"""Local-only checks for SCP progress, byte integrity, and cancellation."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = Path(__file__).with_name("scp-progress.py")
spec = importlib.util.spec_from_file_location("scp_progress", HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProgressTests(unittest.TestCase):
    def test_progress_normalization_and_stall_deduplication(self):
        output = []
        lines = module.ProgressLines(output.append)
        for chunk in ("\rdb 10% 1024KB 1MB/s 00:09 ETA\r",
                      "db 10% 1024KB 0MB/s - stalled -\r",
                      "db 10% 1024KB 0MB/s - stalled -\r",
                      "db 20% 2048KB 1MB/s 00:08 ETA\r\nerror\n"):
            lines.feed(chunk)
        self.assertEqual(len(output), 4)
        self.assertIn("stalled", output[1])
        self.assertIn("20%", output[2])
        self.assertEqual(output[3], "error")

    def test_real_scp_meter_and_complete_copy_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / "source.db", root / "target.db"
            source.write_bytes(os.urandom(4 * 1024 * 1024))
            ssh = root / "local-ssh"
            ssh.write_text('#!/bin/sh\nexec /usr/bin/scp -t "$COPY_TARGET"\n')
            ssh.chmod(0o755)
            process = subprocess.Popen(
                [sys.executable, "-B", str(HELPER), "-O", "-S", str(ssh),
                 "-l", "8192", str(source), "local:unused"],
                env={**os.environ, "COPY_TARGET": str(target)},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                first = process.stdout.readline()
                meter = process.stdout.readline()
                self.assertIn(b"%", meter)
                self.assertIsNone(process.poll(), "Progress must arrive before SCP exits")
                tail, errors = process.communicate(timeout=15)
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate()
            output = first + meter + tail
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(source.read_bytes(), target.read_bytes())
            self.assertIn(b"100%", output)
            self.assertIn(b"ETA", output)
            self.assertNotIn(b"\r", output)

    def test_exit_status_and_separate_stderr(self):
        code = self.invocation([sys.executable, "-c",
                               "import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)"])
        result = subprocess.run([sys.executable, "-B", "-c", code], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, b"out\n")
        self.assertEqual(result.stderr, b"err\n")

    @staticmethod
    def invocation(command):
        return (f"import importlib.util,sys; s=importlib.util.spec_from_file_location('p',{str(HELPER)!r}); "
                f"m=importlib.util.module_from_spec(s); s.loader.exec_module(m); sys.exit(m.run({command!r}))")

    def test_cancel_cleans_up_terminal_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "child.py"
            ready = root / "ready"
            child.write_text(
                "import os,signal,time\n"
                "from pathlib import Path\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "pid=os.fork()\n"
                "if pid:\n"
                f" Path({str(ready)!r}).write_text(str(os.getpid())+' '+str(pid))\n"
                "time.sleep(60)\n")
            process = subprocess.Popen([sys.executable, "-B", "-c",
                                        self.invocation([sys.executable, str(child)])],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            ids = []
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                ids = [int(pid) for pid in ready.read_text().split()]
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=2)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM)
                for pid in ids:
                    state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="],
                                           capture_output=True, text=True).stdout.strip()
                    self.assertTrue(not state or state.startswith("Z"), state)
            finally:
                for pid in ids:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if process.poll() is None:
                    process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
