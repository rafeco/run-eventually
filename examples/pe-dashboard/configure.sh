#!/bin/bash
set -euo pipefail

example_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$example_dir/../.." && pwd)"
dashboard_dir="${PE_DASHBOARD_DIR:-$HOME/pe-dashboard}"
cli="$repo_dir/.build/RunEventually.app/Contents/MacOS/run-eventually"
task_name=pe-dashboard-pipeline
task_path="$example_dir/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -x "$cli" ]; then
    echo "Build the development app with scripts/build-dev-app.sh first." >&2
    exit 1
fi
if [ ! -f "$dashboard_dir/Makefile" ]; then
    echo "Dashboard Makefile missing at $dashboard_dir." >&2
    exit 1
fi
existing_id=$("$cli" list | awk '$2 == "pe-dashboard-pipeline" {print $1}')
if [ -n "$existing_id" ]; then
    echo "Task already exists: $existing_id. No changes made."
    exit 0
fi

# Create paused so a concurrent scheduler cannot launch before the check is attached.
created=$("$cli" add-daily 06:30 America/New_York "$task_name" \
    --paused --cwd "$dashboard_dir" --env "PATH=$task_path" \
    --env CLOUDSDK_CORE_DISABLE_PROMPTS=1 -- /usr/bin/make pipeline)
task_id="${created##*(}"
task_id="${task_id%)}"
"$example_dir/configure-check.sh" "$task_id"
"$cli" resume "$task_id"
echo "Configured $task_name ($task_id) for 06:30 America/New_York."
