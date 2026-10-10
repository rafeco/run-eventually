#!/bin/bash
set -euo pipefail
example_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$example_dir/../.." && pwd)"
dashboard_dir="${PE_DASHBOARD_DIR:-$HOME/pe-dashboard}"
cli="$repo_dir/.build/RunEventually.app/Contents/MacOS/run-eventually"
task_id="${1:?Expected task ID}"
"$cli" add-check "$task_id" network --host 10.248.22.135 --port 22
"$cli" add-check "$task_id" smallstep --subject "${SMALLSTEP_SUBJECT:-${USER}@etsy.com}" --principal "${SMALLSTEP_PRINCIPAL:-$USER}"
"$cli" add-check "$task_id" bq --project etsy-data-warehouse-prod --dataset etsy_atlas
"$cli" set-check "$task_id" --timeout-seconds 30 \
    --failure-message '13=Google ADC authorization unavailable. Run make auth in ~/pe-dashboard.' \
    --failure-message '14=Python credentials unavailable. Check dashboard .env credential overrides and run make auth.' \
    --cwd "$dashboard_dir" \
    --env "PATH=$example_dir/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    --env CLOUDSDK_CORE_DISABLE_PROMPTS=1 -- /opt/homebrew/bin/uv run --no-sync \
    python -B "$example_dir/check.py" --project-dir "$dashboard_dir" --adc-only
