#!/usr/bin/env python3
"""Isolated subprocess tests; --launchd also tests a disposable LaunchAgent."""
import argparse
from contextlib import closing
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / '.build/debug/run-eventually'
APP = ROOT / '.build/RunEventually.app'
LAUNCHD = False
spec = importlib.util.spec_from_file_location('restart_dev', ROOT / 'scripts/restart-dev.py')
restart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restart)


class SignalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='run-eventually-signal-')
        self.folder = Path(self.temporary.name)
        self.database = self.folder / 'state.sqlite'
        self.process = None

    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.temporary.cleanup()

    def call(self, *args):
        return subprocess.check_output([str(CLI), '--database', str(self.database), *args], text=True)

    def once(self, name, command):
        due = (datetime.now(timezone.utc) - timedelta(seconds=60)).isoformat()
        result = self.call('add-once', due, name, '--cwd', str(self.folder), '--', *command)
        return result.split('(')[-1].split(')')[0]

    def start(self):
        with (self.folder / 'service.stderr').open('w') as errors:
            self.process = subprocess.Popen([str(CLI), '--database', str(self.database), 'serve'], stdout=subprocess.DEVNULL, stderr=errors)

    def read(self):
        with closing(sqlite3.connect(self.database.as_uri() + '?mode=ro', uri=True)) as db:
            runs = [json.loads(row[0]) for row in db.execute('SELECT payload FROM runs')]
            events = [json.loads(row[0]) for row in db.execute('SELECT payload FROM activity ORDER BY sequence')]
            return runs, events

    def wait_for(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.process and self.process.poll() is not None:
                self.fail('Scheduler exited before the expected state: ' + (self.folder / 'service.stderr').read_text()[:1_000])
            time.sleep(0.02)
        self.fail('Expected scheduler state did not appear')

    def test_sigterm_drains_task_and_leaves_followup_pending(self):
        first = self.once('slow', ['/bin/sh', '-c', 'sleep 1; touch completed'])
        second = self.once('followup', ['/usr/bin/true'])
        self.start()
        self.wait_for(lambda: any(run['taskID'] == first and run['state'] == 'running' for run in self.read()[0]))
        self.process.send_signal(signal.SIGTERM)
        self.wait_for(lambda: any(event['kind'] == 'schedulerStopping' for event in self.read()[1]))
        self.assertIsNone(self.process.poll(), 'Active operation should be allowed to finish')
        self.assertEqual(self.process.wait(timeout=5), 0)
        runs, events = self.read()
        self.assertEqual(next(run['state'] for run in runs if run['taskID'] == first), 'succeeded')
        self.assertEqual(next(run['state'] for run in runs if run['taskID'] == second), 'pending')
        self.assertTrue((self.folder / 'completed').exists())
        self.assertNotIn('runRecovered', [event['kind'] for event in events])
        self.assertEqual(events[-1]['kind'], 'schedulerStopped')
        runtime, _ = restart.database_status(self.database)
        self.assertIsNone(runtime)

    def test_sigint_drains_check_without_launching_task(self):
        task = self.once('checked', ['/bin/sh', '-c', 'touch should-not-run'])
        self.call('set-check', task, '--cwd', str(self.folder), '--', '/bin/sh', '-c', 'touch checking; sleep 1; touch checked')
        self.start()
        self.wait_for(lambda: (self.folder / 'checking').exists())
        self.process.send_signal(signal.SIGINT)
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertTrue((self.folder / 'checked').exists())
        self.assertFalse((self.folder / 'should-not-run').exists())
        runs, events = self.read()
        self.assertEqual(runs[0]['state'], 'pending')
        self.assertNotIn('runStarted', [event['kind'] for event in events])

    def test_idle_signal_wakes_minute_wait(self):
        self.call('list')
        self.start()
        self.wait_for(lambda: any(event['kind'] == 'waiting' for event in self.read()[1]))
        start = time.monotonic()
        self.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.process.wait(timeout=3), 0)
        self.assertLess(time.monotonic() - start, 3)

    def test_children_do_not_inherit_ignored_termination(self):
        child = self.folder / 'child.py'
        child.write_text('import signal\nassert signal.getsignal(signal.SIGTERM) == signal.SIG_DFL\n')
        task = self.once('signal disposition', [sys.executable, str(child)])
        self.start()
        self.wait_for(lambda: any(run['taskID'] == task and run['state'] == 'succeeded' for run in self.read()[0]))
        self.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.process.wait(timeout=3), 0)


class RestartSafetyTests(unittest.TestCase):
    def test_busy_legacy_helper_is_never_signalled(self):
        with patch.object(restart, 'job_status', return_value={'pid': 123}), \
             patch.object(restart, 'database_status', return_value=(None, 1)), \
             patch.object(restart.time, 'monotonic', side_effect=[0, 2]), \
             patch.object(restart.time, 'sleep'), patch.object(restart.os, 'kill') as kill:
            with self.assertRaises(restart.RestartError):
                restart.legacy_idle_pid('gui/1/test', Path('/unused'), 1)
            kill.assert_not_called()

    def test_legacy_race_resumes_owner_when_work_appears(self):
        with patch.object(restart, 'job_status', return_value={'pid': 123}), \
             patch.object(restart, 'database_status', side_effect=[(None, 0), (None, 1)]), \
             patch.object(restart, 'has_children', return_value=False), \
             patch.object(restart.time, 'monotonic', side_effect=[0, 2]), \
             patch.object(restart.time, 'sleep'), patch.object(restart.os, 'kill') as kill:
            with self.assertRaises(restart.RestartError):
                restart.legacy_idle_pid('gui/1/test', Path('/unused'), 1)
            self.assertEqual(kill.call_args_list[0].args, (123, signal.SIGSTOP))
            self.assertEqual(kill.call_args_list[1].args, (123, signal.SIGCONT))

    def test_atomic_replacement_keeps_old_open_image(self):
        with tempfile.TemporaryDirectory() as folder:
            old = Path(folder) / 'helper'
            new = Path(folder) / 'new'
            old.write_bytes(b'old')
            new.write_bytes(b'new')
            with old.open('rb') as image:
                restart.atomic_copy(new, old)
                self.assertEqual(image.read(), b'old')
            self.assertEqual(old.read_bytes(), b'new')


@unittest.skipUnless(LAUNCHD, 'Pass --launchd for disposable LaunchAgent tests')
class LaunchAgentTests(unittest.TestCase):
    def test_first_install_and_restart_while_task_is_active(self):
        label = 'com.rafeco.RunEventually.test-' + str(os.getpid())
        service = f'gui/{os.getuid()}/{label}'
        with tempfile.TemporaryDirectory(prefix='restart-launchd-') as folder:
            root = Path(folder)
            state = root / 'state'
            command = [sys.executable, str(ROOT / 'scripts/restart-dev.py'), '--skip-build', '--no-app',
                       '--label', label, '--state-dir', str(state), '--agent-dir', str(root / 'agents'),
                       '--log-dir', str(root / 'logs'), '--wait-seconds', '15']
            try:
                subprocess.run(command, check=True, timeout=20)
                first, _ = restart.database_status(state / 'state.sqlite')
                cli = state / 'development/run-eventually'
                due = (datetime.now(timezone.utc) - timedelta(seconds=60)).isoformat()
                subprocess.run([cli, '--database', state / 'state.sqlite', 'add-once', due, 'drain', '--', '/bin/sleep', '2'], check=True, stdout=subprocess.DEVNULL)
                # SIGTERM first wakes the service by requesting a safe restart. A
                # manually queued task will instead be picked up on the fresh start.
                subprocess.run(['launchctl', 'kill', 'SIGTERM', service], check=True)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    runtime, active = restart.database_status(state / 'state.sqlite')
                    if runtime and runtime['sessionID'] != first['sessionID'] and active:
                        break
                    time.sleep(0.02)
                else:
                    self.fail('Disposable task did not start')
                subprocess.run(command, check=True, timeout=20)
                current, active = restart.database_status(state / 'state.sqlite')
                self.assertNotEqual(current['sessionID'], runtime['sessionID'])
                self.assertEqual(active, 0)
                self.assertEqual(current['executableDigest'], hashlib.sha256((APP / 'Contents/MacOS/run-eventually').read_bytes()).hexdigest())
                with closing(sqlite3.connect((state / 'state.sqlite').as_uri() + '?mode=ro', uri=True)) as db:
                    self.assertEqual(db.execute('SELECT state FROM runs').fetchone()[0], 'succeeded')
            finally:
                subprocess.run(['launchctl', 'bootout', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def test_legacy_idle_helper_is_upgraded_without_a_force_kill(self):
        label = 'com.rafeco.RunEventually.legacy-test-' + str(os.getpid())
        service = f'gui/{os.getuid()}/{label}'
        with tempfile.TemporaryDirectory(prefix='restart-legacy-') as folder:
            root = Path(folder)
            state = root / 'state'
            helper = state / 'development/run-eventually'
            helper.parent.mkdir(parents=True)
            # A disposable old-style daemon: no graceful-shutdown capability.
            helper.write_text('#!/bin/sh\nexec /bin/sleep 600\n')
            helper.chmod(0o755)
            logs = root / 'logs'
            logs.mkdir()
            plist = root / (label + '.plist')
            database = state / 'state.sqlite'
            subprocess.run([CLI, '--database', database, 'list'], check=True, stdout=subprocess.DEVNULL)
            restart.write_plist(plist, label, helper, database, logs)
            try:
                subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', plist], check=True)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    old = restart.job_status(service)
                    if old and old['pid']:
                        break
                    time.sleep(0.02)
                else:
                    self.fail('Legacy test helper did not start')
                command = [sys.executable, str(ROOT / 'scripts/restart-dev.py'), '--skip-build', '--no-app',
                           '--label', label, '--state-dir', str(state), '--agent-dir', str(root),
                           '--log-dir', str(logs), '--wait-seconds', '15']
                subprocess.run(command, check=True, timeout=20)
                runtime, active = restart.database_status(database)
                self.assertTrue(runtime['supportsGracefulShutdown'])
                self.assertNotEqual(runtime['processID'], old['pid'])
                self.assertEqual(active, 0)
            finally:
                subprocess.run(['launchctl', 'bootout', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--launchd', action='store_true')
    args, rest = parser.parse_known_args()
    LAUNCHD = args.launchd
    # unittest decorators evaluated before parsing; enable the opt-in suite here.
    if LAUNCHD:
        LaunchAgentTests.__unittest_skip__ = False
    unittest.main(argv=[sys.argv[0], *rest])
