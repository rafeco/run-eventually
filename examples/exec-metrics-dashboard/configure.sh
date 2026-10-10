#!/bin/bash
set -euo pipefail
example_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$example_dir/../.." && pwd)"
dashboard_dir="${EXEC_METRICS_DIR:-$HOME/product-metrics-dashboard}"
daily_time="${EXEC_METRICS_TIME:-06:30}"
cli="$repo_dir/.build/RunEventually.app/Contents/MacOS/run-eventually"
task_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
existing_id=$("$cli" list | awk '$2 == "exec-metrics-dashboard-refresh" {print $1}')
if [ -n "$existing_id" ]; then
    echo "Task already exists: $existing_id. No changes made."
    exit 0
fi
test -f "$dashboard_dir/Makefile"
created=$("$cli" add-daily "$daily_time" America/New_York exec-metrics-dashboard-refresh \
    --paused --cwd "$dashboard_dir" --env "PATH=$task_path" \
    --env CLOUDSDK_CORE_DISABLE_PROMPTS=1 -- /opt/homebrew/bin/uv run --no-sync \
    python -B "$example_dir/run.py" --project-dir "$dashboard_dir")
task_id="${created##*(}"
task_id="${task_id%)}"
"$cli" add-check "$task_id" network --host "${EXEC_METRICS_SSH_HOST:-rcolburn.etsyweb.devenv.etsycloud.com}" --port 22
"$cli" add-check "$task_id" smallstep --subject "${SMALLSTEP_SUBJECT:-${USER}@etsy.com}" --principal "${SMALLSTEP_PRINCIPAL:-$USER}"
"$cli" set-check "$task_id" --timeout-seconds 60 \
    --failure-message '13=Local Google ADC unavailable. Run make auth in ~/product-metrics-dashboard.' \
    --failure-message '14=Local Python Google credentials unavailable. Check dashboard configuration and run make auth.' \
    --cwd "$dashboard_dir" --env "PATH=$task_path" --env CLOUDSDK_CORE_DISABLE_PROMPTS=1 \
    -- /opt/homebrew/bin/uv run --no-sync python -B "$example_dir/check.py" --project-dir "$dashboard_dir" --adc-only
"$cli" resume "$task_id"
echo "Configured exec-metrics-dashboard-refresh ($task_id) for $daily_time America/New_York."
