# Run Eventually

A lazy scheduler for macOS.

A macOS app for scheduled commands that wait until their prerequisites are ready,
including after sleep or downtime.

See the [design document](docs/design.md) for the proposed architecture, scheduling
behavior, user-assisted authentication, and implementation milestones.

The current preview has a persistent command scheduler, one-time and daily
schedules, standard and custom readiness checks, a command-line interface, and a
SwiftUI task list with Run now, pause controls, Stop run, history, and live logs. It catches up after the scheduler starts again and combines
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
so the window and background scheduler stay together. The Tasks status bar and Activity window show when their builds differ.

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

This is a development preview. Bundled startup registration, general command and
schedule editing in the app, browser-assisted sign-in, MCP, and signed
distribution are still to be built. Per-task/global pause and active-run stopping
are available in the app; global pause and cancellation have no CLI command.

## Standard readiness checks

Attach network/VPN, SSH, Smallstep certificate, and BigQuery checks with `add-check`; all attached checks
must pass before launch. They use the task's working directory and environment.
For example, using the installed CLI and the ID returned when creating a task:

```sh
"$cli" add-check "$task_id" network --host internal.example --port 22
"$cli" add-check "$task_id" ssh --host work-vm
"$cli" add-check "$task_id" bq --project work-project --dataset metrics
"$cli" checks "$task_id"
"$cli" check-now "$task_id"
```

Select only the conditions the task needs. `vpn` is an alias for an endpoint
reachability check. SSH runs `true` with batch authentication and the existing
SSH host-verification policy; it does not change SSH configuration or prompt for
host acceptance. Configured SSH helpers can still open SSO even with BatchMode.
For Smallstep/Okta hosts, use `add-check TASK_ID smallstep --subject person@example.com
--principal person` instead. This reads existing user certificates from the task's
SSH agent using `step`, checks the subject, principal, and validity with a 60-second
expiry margin, and never connects, renews, or starts login. Missing/expired
certificates require interactive renewal by the user; inspection failures are check
errors. Local validity does not prove server trust or authorization. Add a separate
network check for the destination if needed, and remove custom SSH polling probes.
BigQuery uses `bq` to list at most one dataset
or read a specified dataset's metadata, without running queries. Metadata access
does not prove permission to run every query. Configure the task's existing
credential context rather than copying secrets into its definition.

The sidebar leads with the task name, schedule, and current status. **Later Today**
means today's scheduled time has not arrived; it does not create a pending run or
reuse yesterday's success as today's status. The last successful run is shown
separately. Running jobs from older scheduler versions show checks as **Passed**
at launch when individual results were not recorded.

The app presents pending work as **Waiting**, with compact Network, SSH, and
Google Cloud pills showing the latest per-check result. A check skipped because
an earlier prerequisite blocked the scan shows **Not checked**, never an assumed
success. Sign-in instructions and diagnostic details are available under
**Waiting details**; waiting is an ordinary queued state. The CLI and scheduler
retain the readiness categories and the app shows the next check time. Transient and inconclusive failures back off from one minute to a
maximum of fifteen; action-required conditions recheck every five minutes.
**Recheck**, or `recheck TASK_ID`, clears that delay for the next scheduler scan.
`check-now` probes without launching a task or modifying its schedule (exit 2 if
not ready). `remove-check TASK_ID CHECK_ID` removes one provider; use `custom` as
the ID to remove the legacy command check. Existing custom checks still run and
must also pass. Missing tools and known credential or access problems require
action; uncertain failures are not diagnosed as expired credentials.

Assume the task already runs manually. Readiness checks concern changing network
and credential availability, not application setup or API keys in `.env`.

## Pause and interrupted runs

Use **Pause task** on a task row to hold that task until **Resume task** is chosen.
Use **Pause all** in the Tasks status bar to pause scheduling globally until
**Resume all** is chosen. These preferences survive app/service restarts; a global
resume does not unpause individually paused tasks. Existing commands finish
normally. Resume checks queued and missed work on the next scheduler scan.

The status bar also shows when the scheduler is stopped, draining for a restart,
or running a different build. A build mismatch alone does not imply that an
otherwise running scheduler has paused. Older services advertise their capabilities;
a requested global pause takes effect when the updated service starts.

Task deadlines use a continuous clock: the one-hour run limit includes laptop
sleep. Waking is recorded in Activity and run details. After two minutes without
new output following a wake, the app shows a quiet-progress notice. Quiet output
alone does not prove a stalled command and does not trigger an automatic retry.

**Stop run** asks the scheduler to signal the command's verified, isolated local
process group, allowing one second of cleanup before forcing remaining local
processes to exit. If process-group isolation cannot be verified, only the parent
is signaled; detached processes are not covered. The run becomes **Cancelled**
and keeps its logs and reason.
Timeouts are **Failed**, with a specific explanation if sleep crossed the deadline.
Remote jobs can continue after local processes stop; inspect output before using
**Run now** to retry. Neither cancellation nor a timeout automatically reruns a
command. The new stop control requires an updated scheduler.

Check pills appear in the sidebar only while work is pending. Filled backgrounds
use white text for ready/failed states and dark text for neutral waiting states.
Failed or cancelled runs show a red reason pill; absent reasons are reported as
unrecorded instead of inferred from arbitrary command output.

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
environment values; task output remains in the selected run's logs.
Use `run-eventually activity` to print the latest 200 events from the CLI.

Select a running task's run to follow standard output and standard error live.
The log panes update twice a second, follow new output while you are at the
bottom, and let you scroll back without being pulled away. New runs retain full
output in separate files beside the database, under `state.sqlite.logs/`; neither
file capture nor display truncates it. SQLite retains small previews for older
clients. Existing runs show all output previously captured, but output discarded
by older versions cannot be recovered. Log files currently require manual
retention. Python tasks default to unbuffered output unless the task explicitly
sets `PYTHONUNBUFFERED`; other programs may need their own flushing options.

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
The installed skill is available on the next turn. Copies installed in other
agent environments must be refreshed separately after this repo's skill changes;
a scheduler rebuild does not update those copies. Invoke it as `$run-eventually`
or ask, “Use Run Eventually to run this project's FX refresh every morning at
7 Eastern.”

If the executable is outside the usual app or development locations, provide its
absolute path in the session or set `RUN_EVENTUALLY_CLI` for skill discovery.
