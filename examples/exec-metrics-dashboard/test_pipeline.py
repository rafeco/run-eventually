import hashlib
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


local = load("run")
remote = load("remote")
preflight = load("check")


def database(path, value):
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE metrics(value)")
        connection.execute("INSERT INTO metrics VALUES (?)", (value,))


def value(path):
    with sqlite3.connect(path) as connection:
        return connection.execute("SELECT value FROM metrics").fetchone()[0]


class PipelineTests(unittest.TestCase):
    def test_snapshot_includes_committed_wal_data(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "source.db", Path(directory) / "copy.db"
            with sqlite3.connect(source) as connection:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("CREATE TABLE metrics(value)")
                connection.execute("INSERT INTO metrics VALUES (7)")
                connection.commit()
                local.snapshot(source, target)
                self.assertEqual(value(target), 7)

    def test_deployment_success_and_startup_rollback(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                old, incoming = project / "metrics.db", project / ".metrics-test.db"
                database(old, 1)
                database(incoming, 2)
                digest = hashlib.sha256(incoming.read_bytes()).hexdigest()
                with patch.object(remote, "PROJECT", project), patch.object(remote.os, "access", return_value=True), \
                     patch.object(remote, "listening", return_value=False), patch.object(remote, "stop"), \
                     patch.object(remote, "start", side_effect=[RuntimeError("startup failed"), None] if fail else None):
                    if fail:
                        with self.assertRaisesRegex(RuntimeError, "startup failed"):
                            remote.deploy(incoming, digest)
                    else:
                        remote.deploy(incoming, digest)
                        self.assertEqual(value(project / "metrics.previous.db"), 1)
                self.assertEqual(value(old), 1 if fail else 2)

    def test_corrupt_upload_never_stops_dashboard(self):
        with tempfile.TemporaryDirectory() as directory:
            incoming = Path(directory) / ".metrics-test.db"
            incoming.write_bytes(b"not a database")
            with patch.object(remote, "PROJECT", Path(directory)), patch.object(remote, "stop") as stop:
                with self.assertRaisesRegex(RuntimeError, "checksum"):
                    remote.deploy(incoming, "wrong")
                stop.assert_not_called()

    def test_unmanaged_listener_preserves_database(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            incoming = project / ".metrics-test.db"
            database(incoming, 2)
            with patch.object(remote, "PROJECT", project), patch.object(remote, "listening", return_value=True), \
                 patch.object(remote, "managed", return_value=False), patch.object(remote, "stop") as stop:
                with self.assertRaisesRegex(RuntimeError, "unmanaged"):
                    remote.deploy(incoming, hashlib.sha256(incoming.read_bytes()).hexdigest())
                stop.assert_not_called()

    def test_preflight_blocks_cloud_and_ssh_failures(self):
        for outcomes, adc, expected in [([False], True, 12), ([True, False], True, 13),
                                        ([True, True], False, 14), ([True, True, False], True, 15),
                                        ([True, True, True], True, 0)]:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                project = Path(directory)
                (project / "Makefile").touch()
                with patch.object(preflight.shutil, "which", return_value="tool"), \
                     patch.object(preflight.shared, "command_ready", side_effect=outcomes), \
                     patch.object(preflight.shared, "adc_ready", return_value=adc):
                    self.assertEqual(preflight.check(project), expected)


if __name__ == "__main__":
    unittest.main()
