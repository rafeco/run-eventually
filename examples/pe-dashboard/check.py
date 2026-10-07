"""Read-only readiness checks; run with pe-dashboard's uv Python environment."""

import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess


def command_ready(arguments):
    try:
        result = subprocess.run(
            arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=10,
            env={**os.environ, "CLOUDSDK_CORE_DISABLE_PROMPTS": "1"},
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def network_ready(host):
    try:
        with socket.create_connection((host, 22), timeout=3):
            return True
    except OSError:
        return False


def adc_ready(project_dir):
    # Match the Python pipeline's actual credential lookup, including its .env.
    # Neither tokens nor exception messages are printed or persisted.
    try:
        from dotenv import load_dotenv
        import google.auth
        from google.auth.transport.requests import Request

        class BoundedRequest(Request):
            def __call__(self, *args, **kwargs):
                kwargs["timeout"] = 5
                return super().__call__(*args, **kwargs)

        load_dotenv(project_dir / ".env")
        credentials, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        credentials.refresh(BoundedRequest())
        return credentials.valid
    except Exception:
        return False


def check(project_dir, host):
    if not (project_dir / "Makefile").is_file():
        print("BLOCKED: dashboard directory or Makefile missing.")
        return 2
    if any(shutil.which(tool) is None for tool in ("gcloud", "bq", "uv", "make")):
        print("BLOCKED: install gcloud, bq, uv, and make; check the configured PATH.")
        return 2
    if not network_ready(host):
        print("BLOCKED: production SSH endpoint unreachable. Connect the work VPN.")
        return 11
    if not command_ready(["gcloud", "auth", "print-access-token", "--quiet"]):
        print("BLOCKED: Google CLI authorization unavailable. Run gcloud auth login.")
        return 12
    if not command_ready(["gcloud", "auth", "application-default", "print-access-token", "--quiet"]):
        print("BLOCKED: Google ADC authorization unavailable. Run make auth in pe-dashboard.")
        return 13
    if not adc_ready(project_dir):
        print("BLOCKED: Python ADC unavailable. Check .env credential overrides and run make auth.")
        return 14
    if not command_ready([
        "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
        "-o", "ConnectionAttempts=1",
        host, "true",
    ]):
        print("BLOCKED: SSH authorization unavailable. Renew SSH credentials or approve the host in Terminal.")
        return 15
    print("READY: production endpoint, Google CLI, ADC, and noninteractive SSH.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, required=True)
    parser.add_argument("--host", default="10.248.22.135")
    args = parser.parse_args()
    raise SystemExit(check(args.project_dir, args.host))
