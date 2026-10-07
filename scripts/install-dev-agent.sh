#!/bin/bash
set -euo pipefail

# Development bridge until the bundled SMAppService helper is implemented.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_cli="$repo_dir/.build/RunEventually.app/Contents/MacOS/run-eventually"
label=com.rafeco.RunEventually.development
agent_dir="$HOME/Library/LaunchAgents"
state_dir="$HOME/Library/Application Support/RunEventually"
log_dir="$HOME/Library/Logs/RunEventually"
plist="$agent_dir/$label.plist"
service_cli="$state_dir/development/run-eventually"

if [ ! -x "$source_cli" ]; then
    echo "Build the development app first." >&2
    exit 1
fi
if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    echo "Development scheduler is already registered. Stop it deliberately before replacing it." >&2
    exit 1
fi
mkdir -p "$agent_dir" "$state_dir/development" "$log_dir"
cp "$source_cli" "$service_cli"

# Serialize paths through plistlib rather than interpolating them into XML.
/usr/bin/python3 - "$plist" "$label" "$service_cli" "$state_dir" "$log_dir" <<'PY'
import os
import plistlib
import sys
path, label, executable, state, logs = sys.argv[1:]
with open(path, "wb") as output:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": [executable, "--database", os.path.join(state, "state.sqlite"), "serve"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
        "StandardOutPath": os.path.join(logs, "scheduler.log"),
        "StandardErrorPath": os.path.join(logs, "scheduler-error.log"),
    }, output)
PY
plutil -lint "$plist"
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Development scheduler registered at login: $label"
