"""Read-only prerequisites using the existing dashboard credential check."""
import argparse
import importlib.util
from pathlib import Path
import shutil

spec = importlib.util.spec_from_file_location("dashboard_check", Path(__file__).parents[1] / "pe-dashboard/check.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def check(project, remaining_only=False, adc_only=False):
    remaining_only = remaining_only or adc_only
    if not remaining_only and (not (project / "Makefile").is_file() or any(shutil.which(tool) is None for tool in ("gcloud", "uv", "make", "ssh", "scp"))):
        print("BLOCKED: local dashboard or required tools missing")
        return 2
    if not remaining_only and not shared.command_ready(["gcloud", "auth", "print-access-token", "--quiet"]):
        return 12
    if not shared.command_ready(["gcloud", "auth", "application-default", "print-access-token", "--quiet"]):
        return 13
    if not shared.adc_ready(project):
        return 14
    if adc_only:
        print("READY: local Google ADC credentials")
        return 0
    remote = "test -x ~/exec-metrics-dashboard/.venv/bin/python && command -v python3 >/dev/null && command -v tmux >/dev/null"
    if not shared.command_ready(["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "vm", remote]):
        return 15
    print("READY: local Google credentials and VM dashboard runtime")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, required=True)
    parser.add_argument("--remaining-only", action="store_true", help="Check ADC and the project-specific VM runtime after standard SSH readiness")
    parser.add_argument("--adc-only", action="store_true", help="Check only local ADC; never connect over SSH")
    args = parser.parse_args()
    raise SystemExit(check(args.project_dir, remaining_only=args.remaining_only, adc_only=args.adc_only))
