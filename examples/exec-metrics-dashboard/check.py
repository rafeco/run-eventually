"""Read-only prerequisites using the existing dashboard credential check."""
import argparse
import importlib.util
from pathlib import Path
import shutil

spec = importlib.util.spec_from_file_location("dashboard_check", Path(__file__).parents[1] / "pe-dashboard/check.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def check(project):
    if not (project / "Makefile").is_file() or any(shutil.which(tool) is None for tool in ("gcloud", "uv", "make", "ssh", "scp")):
        print("BLOCKED: local dashboard or required tools missing")
        return 2
    if not shared.command_ready(["gcloud", "auth", "print-access-token", "--quiet"]):
        return 12
    if not shared.command_ready(["gcloud", "auth", "application-default", "print-access-token", "--quiet"]):
        return 13
    if not shared.adc_ready(project):
        return 14
    remote = "test -x ~/exec-metrics-dashboard/.venv/bin/python && command -v python3 >/dev/null && command -v tmux >/dev/null"
    if not shared.command_ready(["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "vm", remote]):
        return 15
    print("READY: local Google credentials and VM dashboard runtime")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, required=True)
    raise SystemExit(check(parser.parse_args().project_dir))
