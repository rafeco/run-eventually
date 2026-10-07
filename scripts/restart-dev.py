#!/usr/bin/env python3
"""Build and restart the development UI/helper without interrupting task execution."""
import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time


class RestartError(RuntimeError):
    pass


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def job_status(service):
    result = subprocess.run(['launchctl', 'print', service], capture_output=True, text=True)
    if result.returncode:
        # Distinguish an absent job from an unavailable GUI launchd domain.
        domain = service.rsplit('/', 1)[0]
        run(['launchctl', 'print', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return None
    pid = re.search(r'^\s*pid = (\d+)\s*$', result.stdout, re.MULTILINE)
    program = re.search(r'^\s*program = (.+)$', result.stdout, re.MULTILINE)
    return {'pid': int(pid.group(1)) if pid else None,
            'program': program.group(1).strip() if program else None}


def database_status(database):
    if not database.exists():
        return None, 0
    # Do not create/migrate state while probing an older live service.
    with closing(sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
        active = db.execute("SELECT COUNT(*) FROM runs WHERE state IN ('starting','running')").fetchone()[0]
        runtime = None
        if db.execute("SELECT 1 FROM sqlite_master WHERE name='scheduler_runtime'").fetchone():
            row = db.execute('SELECT payload FROM scheduler_runtime WHERE singleton=1').fetchone()
            runtime = json.loads(row[0]) if row else None
        return runtime, active


def processes():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
    rows = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    return rows


def has_children(pid):
    return any(parent == pid for _, parent, _ in processes())


def matching_runtime(runtime, job):
    return runtime is not None and job is not None and runtime.get('processID') == job['pid']


def database_owned(database):
    lock_path = Path(str(database) + '.scheduler.lock')
    if not lock_path.exists():
        return False
    with lock_path.open('rb') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(lock, fcntl.LOCK_UN)
        return False


def write_plist(path, label, helper, database, log_dir):
    with path.open('wb') as stream:
        plistlib.dump({
            'Label': label,
            'ProgramArguments': [str(helper), '--database', str(database), 'serve'],
            'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1,
            'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
            'StandardOutPath': str(log_dir / 'scheduler.log'),
            'StandardErrorPath': str(log_dir / 'scheduler-error.log'),
        }, stream)


def atomic_copy(source, destination):
    descriptor, name = tempfile.mkstemp(prefix=destination.name + '.next-', dir=destination.parent)
    os.close(descriptor)
    staged = Path(name)
    try:
        shutil.copy2(source, staged)
        if digest(staged) != digest(source):
            raise RestartError('Staged helper did not match the build.')
        os.replace(staged, destination)
    finally:
        staged.unlink(missing_ok=True)


def legacy_idle_pid(service, database, deadline):
    """A legacy helper cannot drain. Freeze only a seemingly idle owner, then
    recheck durable launch state AND children while it cannot start new work.
    This closes the idle-check/termination race without signalling a busy helper.
    """
    print('Older scheduler: waiting for an idle moment before its first update.', flush=True)
    while time.monotonic() < deadline:
        job = job_status(service)
        if not job or not job['pid']:
            return None
        pid = job['pid']
        _, active = database_status(database)
        if active == 0 and not has_children(pid):
            try:
                os.kill(pid, signal.SIGSTOP)
            except ProcessLookupError:
                continue
            keep_stopped = False
            try:
                current = job_status(service)
                _, active = database_status(database)
                if current and current['pid'] == pid and active == 0 and not has_children(pid):
                    keep_stopped = True
                    return pid
            finally:
                if not keep_stopped:
                    try:
                        os.kill(pid, signal.SIGCONT)
                    except ProcessLookupError:
                        pass
        time.sleep(0.5)
    raise RestartError('Older scheduler is still busy. It was left running; retry after its task/check finishes.')


def wait_for_build(service, database, expected_digest, old_session, deadline):
    while time.monotonic() < deadline:
        job = job_status(service)
        runtime, _ = database_status(database)
        if (matching_runtime(runtime, job) and runtime.get('executableDigest') == expected_digest
                and runtime.get('supportsGracefulShutdown') and runtime.get('sessionID') != old_session):
            return runtime
        if job and not job['pid']:
            # A normally exited job with a different KeepAlive policy may need an
            # explicit start. Never use -k: it kills a process that may own work.
            run(['launchctl', 'kickstart', service], stdout=subprocess.DEVNULL)
        time.sleep(0.5)
    raise RestartError('The updated helper is installed, but its restart has not completed. '
                       'An active operation may still be draining; it was not killed. '
                       'Inspect Activity and rerun this script after it finishes.')


def restart_app(app, deadline):
    executable = str(app / 'Contents/MacOS/run-eventually-desktop')
    pids = [pid for pid, _, command in processes() if command == executable]
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    while time.monotonic() < deadline:
        remaining = {pid for pid, _, command in processes() if command == executable}
        if not remaining.intersection(pids):
            break
        time.sleep(0.1)
    else:
        raise RestartError('The development window did not quit. The scheduler was updated; quit and reopen the app.')
    run(['open', '-n', app])
    while time.monotonic() < deadline:
        if any(command == executable for _, _, command in processes()):
            print('Development app reopened.', flush=True)
            return
        time.sleep(0.1)
    raise RestartError('App launch was requested but its process could not be verified.')


def update(args):
    state = args.state_dir.expanduser().resolve()
    helper = state / 'development/run-eventually'
    database = state / 'state.sqlite'
    plist = args.agent_dir.expanduser().resolve() / (args.label + '.plist')
    logs = args.log_dir.expanduser().resolve()
    service = f'gui/{os.getuid()}/{args.label}'
    app = args.project_dir.resolve() / '.build/RunEventually.app'
    source = app / 'Contents/MacOS/run-eventually'
    helper.parent.mkdir(parents=True, exist_ok=True)
    with (helper.parent / 'restart.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RestartError('Another development build/restart is already in progress.')
        if not args.skip_build:
            print('Building app and scheduler before changing running processes…', flush=True)
            run([args.project_dir.resolve() / 'scripts/build-dev-app.sh'])
        if not source.is_file():
            raise RestartError('Built helper is missing. Run without --skip-build.')
        expected = digest(source)
        if subprocess.check_output([source, 'version'], text=True).strip() != expected:
            raise RestartError('Build does not support verified development restarts.')
        job = job_status(service)
        if job and (not job['program'] or Path(job['program']).resolve() != helper):
            raise RestartError('The launchd label belongs to a different executable; refusing to replace it.')
        if (not job or not job['pid']) and database_owned(database):
            raise RestartError('A scheduler outside this development LaunchAgent owns the database. '
                               'Stop it gracefully before using the development updater.')
        if plist.exists():
            config = plistlib.loads(plist.read_bytes())
            arguments = config.get('ProgramArguments', [])
            same_arguments = (len(arguments) == 4 and arguments[1] == '--database' and arguments[3] == 'serve'
                              and Path(arguments[0]).resolve() == helper and Path(arguments[2]).resolve() == database)
            if config.get('Label') != args.label or not same_arguments:
                raise RestartError('Existing LaunchAgent uses different paths or arguments; refusing to change its configuration.')
        elif job:
            raise RestartError('Registered LaunchAgent has no matching plist; refusing to guess its configuration.')
        else:
            plist.parent.mkdir(parents=True, exist_ok=True)
            logs.mkdir(parents=True, exist_ok=True)
            write_plist(plist, args.label, helper, database, logs)
        deadline = time.monotonic() + args.wait_seconds
        runtime, _ = database_status(database)
        graceful = matching_runtime(runtime, job) and runtime.get('supportsGracefulShutdown')
        old_session = runtime.get('sessionID') if matching_runtime(runtime, job) else None
        frozen_pid = None
        if job and job['pid'] and not graceful:
            frozen_pid = legacy_idle_pid(service, database, deadline)
        replaced = False
        requested = False
        backup = helper.with_name('run-eventually.previous')
        try:
            if helper.exists():
                shutil.copy2(helper, backup)
            # A rename preserves the image of the old running process. Never
            # overwrite its executable in place while it may still own a run.
            atomic_copy(source, helper)
            replaced = True
            current = job_status(service)
            if current and current['pid']:
                # Revalidate ownership before delivering a stop signal.
                if job and current['pid'] != job['pid']:
                    raise RestartError('Scheduler ownership changed during update; retry after inspecting its status.')
                print('Requesting scheduler restart; active work will finish first.', flush=True)
                run(['launchctl', 'kill', 'SIGTERM', service])
                requested = True
            elif current:
                run(['launchctl', 'kickstart', service])
                requested = True
            else:
                run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', plist])
                requested = True
        except Exception:
            if replaced and not requested and backup.exists():
                os.replace(backup, helper)
            raise
        finally:
            if frozen_pid is not None:
                try:
                    os.kill(frozen_pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
        runtime = wait_for_build(service, database, expected, old_session, deadline)
        backup.unlink(missing_ok=True)
        print(f"Scheduler running new build {expected[:12]} (PID {runtime['processID']}).", flush=True)
        if not args.no_app:
            restart_app(app, time.monotonic() + 15)


def main():
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-dir', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--wait-seconds', type=float, default=300, help='Maximum wait for task drain/restart (default: 300). Never force kills work.')
    parser.add_argument('--skip-build', action='store_true', help='Use an already built app.')
    parser.add_argument('--no-app', action='store_true', help='Update only the background helper; useful for isolated tests.')
    parser.add_argument('--state-dir', type=Path, default=home / 'Library/Application Support/RunEventually')
    parser.add_argument('--agent-dir', type=Path, default=home / 'Library/LaunchAgents')
    parser.add_argument('--log-dir', type=Path, default=home / 'Library/Logs/RunEventually')
    parser.add_argument('--label', default='com.rafeco.RunEventually.development')
    args = parser.parse_args()
    if not 0 < args.wait_seconds < float('inf'):
        parser.error('--wait-seconds must be finite and positive')
    if not re.fullmatch(r'[A-Za-z0-9._-]+', args.label):
        parser.error('Invalid LaunchAgent label')
    try:
        update(args)
    except KeyboardInterrupt:
        print('Stopped waiting. No task was force-stopped; an already requested graceful restart will finish after draining.', file=sys.stderr)
        return 130
    except (RestartError, subprocess.SubprocessError, OSError, sqlite3.Error) as error:
        print(f'Development restart stopped: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
