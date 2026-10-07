#!/bin/bash
set -euo pipefail
example_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$example_dir/../.." && pwd)"
dashboard_dir="${PE_DASHBOARD_DIR:-$HOME/pe-dashboard}"
cli="$repo_dir/.build/RunEventually.app/Contents/MacOS/run-eventually"
"$cli" set-check "${1:?Expected task ID}" --timeout-seconds 60 \
    --failure-message '2=Local tools or dashboard directory missing. Check the configured working directory and PATH.' \
    --failure-message '11=Waiting for the work network. Connect the VPN; production SSH port is unreachable.' \
    --failure-message '12=Google CLI authorization unavailable. Run gcloud auth login in Terminal.' \
    --failure-message '13=Google ADC authorization unavailable. Run make auth in ~/pe-dashboard.' \
    --failure-message '14=Python credentials unavailable. Check dashboard .env credential overrides and run make auth.' \
    --failure-message '15=Noninteractive SSH is unavailable or timed out. Renew work SSH credentials and verify ssh -o BatchMode=yes 10.248.22.135 true in Terminal.' \
    --cwd "$dashboard_dir" \
    --env "PATH=$example_dir/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    --env CLOUDSDK_CORE_DISABLE_PROMPTS=1 -- /opt/homebrew/bin/uv run --no-sync \
    python -B "$example_dir/check.py" --project-dir "$dashboard_dir"
