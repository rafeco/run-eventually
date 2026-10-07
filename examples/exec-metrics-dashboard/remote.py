"""Executed over SSH on the VM; Google credentials are never used."""
import fcntl
import hashlib
import os
from pathlib import Path
import shlex
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.request

PROJECT = Path.home() / "exec-metrics-dashboard"
SESSION = "exec-metrics-dashboard"


def listening():
    with socket.socket() as client:
        client.settimeout(1)
        return client.connect_ex(("127.0.0.1", 8088)) == 0


def managed():
    return subprocess.run(["tmux", "has-session", "-t", "=" + SESSION],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def stop():
    if managed():
        subprocess.run(["tmux", "kill-session", "-t", "=" + SESSION], check=True)
    for _ in range(30):
        if not listening():
            return
        time.sleep(1)
    raise RuntimeError("Dashboard listener did not stop; database was not replaced")


def start():
    command = "exec env DB_BACKEND=sqlite DATABASE=metrics.db FLASK_DEBUG=0 PORT=8088 "
    command += shlex.quote(str(PROJECT / ".venv/bin/python")) + " -u app.py >> dashboard.log 2>&1"
    subprocess.run(["tmux", "new-session", "-d", "-s", SESSION, "-c", str(PROJECT), command], check=True)
    for _ in range(30):
        if not managed():
            break
        try:
            with urllib.request.urlopen("http://127.0.0.1:8088/healthz", timeout=2) as response:
                if response.status == 200:
                    return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError("Dashboard startup failed; inspect dashboard.log on the VM")


def checkpoint(database):
    if database.exists():
        with sqlite3.connect(database) as connection:
            if connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] != 0:
                raise RuntimeError("Database is busy; refusing to replace it")
    for suffix in ("-wal", "-shm"):
        Path(str(database) + suffix).unlink(missing_ok=True)


def deploy(incoming, digest):
    database = PROJECT / "metrics.db"
    previous = PROJECT / "metrics.previous.db"
    with incoming.open("rb") as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
        if checksum.hexdigest() != digest:
            raise RuntimeError("Uploaded database checksum mismatch")
    with sqlite3.connect(incoming.as_uri() + "?mode=ro", uri=True) as connection:
        if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("Uploaded database failed SQLite validation")
    if listening() and not managed():
        raise RuntimeError("Port 8088 belongs to an unmanaged process; stop it before scheduling deployment")
    if not os.access(PROJECT / ".venv/bin/python", os.X_OK):
        raise RuntimeError("VM dashboard Python environment is missing")
    stop()
    checkpoint(database)
    had_previous = database.exists()
    if had_previous:
        os.replace(database, previous)
    os.replace(incoming, database)
    try:
        start()
    except Exception:
        stop()
        checkpoint(database)
        if had_previous:
            os.replace(previous, database)
            start()
            print("Previous database restored and dashboard restarted", flush=True)
        raise
    print("Dashboard healthy on port 8088; previous database retained", flush=True)


if __name__ == "__main__":
    name, digest = sys.argv[1:]
    if not name.startswith(".metrics-") or Path(name).name != name:
        raise ValueError("Invalid incoming database name")
    with (PROJECT / ".scheduler-deploy.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deploy(PROJECT / name, digest)
