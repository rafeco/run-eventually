# Run Eventually

A lazy scheduler for macOS.

A macOS app for scheduled commands that wait until their prerequisites are ready,
including after sleep or downtime.

See the [design document](docs/design.md) for the proposed architecture, scheduling
behavior, user-assisted authentication, and implementation milestones.

The first working slice has a persistent command scheduler, one-time and daily
schedules, custom prerequisite commands, a command-line interface, and a
SwiftUI status window with a Run now button. It catches up after the scheduler starts again and combines
missed daily occurrences into one pending run. It conservatively holds a run for
review if the scheduler stops during command execution.

Build a local preview app with `scripts/build-dev-app.sh`, then open
`.build/RunEventually.app`. Start its scheduler separately with:

```sh
.build/RunEventually.app/Contents/MacOS/run-eventually serve
```

For the normal development loop, run:

```sh
scripts/dev.sh
```

This builds first, updates the development LaunchAgent's helper, and restarts the
preview window after verifying the new scheduler's running build. It installs the
development LaunchAgent on first use. Keep using this command after code changes
so the window and background scheduler stay together. The Activity window warns
when their builds differ.

The scheduler handles SIGTERM and SIGINT by finishing its current command or
readiness check, recording the result, and exiting without admitting more work.
Idle waits wake immediately. `launchd` starts the updated helper after that exit.
The script uses atomic executable replacement, never `kickstart -k`, and does not
force-stop work. It waits up to five minutes by default; use
`scripts/dev.sh --wait-seconds 3600` for a longer task. If that wait expires after
the update is staged, draining continues and launchd will start the new helper
when the operation finishes; rerun the script afterward to reopen the window.

An older helper without this signal handler is updated only when it has neither
an active run nor child processes. The script briefly freezes an apparently idle
helper and rechecks both before stopping it, so it cannot launch work between the
idle check and restart. If it stays busy, the script leaves it running and asks
you to retry later. Other manually started schedulers are not stopped.

`--skip-build` uses the existing build; `--no-app` updates just the scheduler.
Disposable LaunchAgent tests can be run after building with
`python3 scripts/test-dev-restart.py --launchd`. They use a separate label and
temporary state, and leave the real development scheduler alone.

Tasks can currently be added from the command line. For example:

```sh
.build/RunEventually.app/Contents/MacOS/run-eventually \
  add-daily 06:30 America/New_York daily-report \
  --cwd /absolute/path/to/project -- /usr/bin/make daily-report
```

Use `run-eventually help` for the remaining commands, including `set-check`,
`pause`, `resume`, `run-now`, `runs`, and `tick`. Run `scripts/verify.sh` for the test suite
and end-to-end checks.

Run now queues work for the existing scheduler rather than launching a command
in the app. It reuses pending or active work, respects prerequisite checks, and
does not shift the recurring schedule. Paused tasks must be resumed first, and
unknown outcomes must be resolved before another run. The scheduler normally
picks up requests within a minute. Closing the window does not discard a request.

See the [morning dashboard example](examples/pe-dashboard/README.md) for a daily
`make pipeline` task that waits for Google authorization and production SSH
access, plus a temporary development LaunchAgent for login startup.

The [executive metrics dashboard example](examples/exec-metrics-dashboard/README.md)
runs ETL locally, uploads a validated SQLite snapshot to the VM, and restarts
the dashboard in tmux without Google authorization on the VM.

This is a development preview. Bundled startup registration, task editing in the app,
reusable VPN and Google Cloud checks, browser-assisted sign-in, MCP, and signed
distribution are still to be built.

## Watching activity

The task list opens at launch and when you click the app in the Dock. Use
**View → Task List** (⌘1) or **View → Activity** (⌘2) to reopen either window
after closing it.

Click **Activity** in the app's toolbar to open the live activity window. It
refreshes every second and shows scheduler scans, schedule decisions, readiness
check attempts and outcomes, queued requests, task execution, and recovery.
The header shows the scheduler's current operation and whether its process lock
is held. Filter by task, readiness checks, task execution, or warnings and errors;
pause updates to inspect an event without stopping the scheduler.

Activity persists across app restarts in the scheduler database. The window shows
the latest 500 events, and the database retains a rolling history of 5,000.
Operational events contain summaries rather than command output, arguments, or
environment values; completed task output remains in the selected run's logs.
Use `run-eventually activity` to print the latest 200 events from the CLI.

Existing tasks are preserved when the activity table is added. An already running
older scheduler must be restarted with the new executable before it emits activity;
wait for active tasks to finish before replacing or restarting it.

## Agent skill

The [Run Eventually skill](skills/run-eventually/SKILL.md) lets agents configure
tasks from other project sessions through the current CLI. It discovers the local
executable, checks existing tasks, configures environments and readiness checks,
and verifies saved definitions. It does not install or start the scheduler.
MCP support is planned; the skill works without it.

To install from this checkout, copy `skills/run-eventually` into your personal
Codex skills directory (`$CODEX_HOME/skills`, or `~/.codex/skills` by default).
Preserve any existing skill with that name rather than blindly overwriting it.
The installed skill is available on the next turn. Invoke it as `$run-eventually`
or ask, “Use Run Eventually to run this project's FX refresh every morning at
7 Eastern.”

If the executable is outside the usual app or development locations, provide its
absolute path in the session or set `RUN_EVENTUALLY_CLI` for skill discovery.
