#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 "$repo_dir/scripts/restart-dev.py" --project-dir "$repo_dir" "$@"
