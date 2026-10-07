"""Refresh locally, upload a SQLite snapshot, and restart the VM dashboard."""
import argparse
import hashlib
from pathlib import Path
import shlex
import sqlite3
import subprocess
import tempfile
import uuid

SSH = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]


def snapshot(source, target):
    with sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True) as src, sqlite3.connect(target) as dst:
        src.backup(dst)
        if dst.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("SQLite snapshot failed validation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, required=True)
    parser.add_argument("--host", default="vm")
    args = parser.parse_args()
    project = args.project_dir.resolve()
    # Separate commands preserve order even if MAKEFLAGS enables parallel make.
    for target in ("datamart-etl", "refresh"):
        print(f"Running local {target}", flush=True)
        subprocess.run(["/usr/bin/make", target], cwd=project, check=True)
    with tempfile.TemporaryDirectory(prefix="exec-metrics-") as directory:
        database = Path(directory) / "metrics.db"
        snapshot(project / "metrics.db", database)
        with database.open("rb") as stream:
            checksum = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                checksum.update(chunk)
            digest = checksum.hexdigest()
        incoming = f".metrics-{uuid.uuid4().hex}.db"
        print("Uploading validated database snapshot", flush=True)
        subprocess.run(["/usr/bin/scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                        str(database), f"{args.host}:exec-metrics-dashboard/{incoming}"], check=True)
        remote = Path(__file__).with_name("remote.py").read_text()
        command = "python3 - " + shlex.join([incoming, digest])
        subprocess.run([*SSH, args.host, command], input=remote, text=True, check=True)
    print("VM dashboard refreshed and healthy", flush=True)


if __name__ == "__main__":
    main()
