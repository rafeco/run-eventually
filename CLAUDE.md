# Run Eventually

Run Eventually is a macOS app for scheduled commands that remain pending until
their prerequisites are satisfied, including after sleep or downtime.

Read `README.md` for current usage and `docs/design.md` for the agreed architecture
and scheduling semantics. The design describes the intended release; do not
assume all of it is implemented.

## Architecture and scope

- Swift 6 package targeting macOS 13 or later; native SwiftUI interface.
- `Sources/RunEventuallyCore`: models, calendar planning, SQLite persistence,
  command execution, and scheduler reconciliation.
- `Sources/RunEventuallyCLI`: prototype task management and `tick`/`serve`.
- `Sources/RunEventuallyDesktop`: task status, history, logs, and manual run requests.
- The Activity window refreshes every second from persistent operational events;
  keep events separate from command output and credentials. Retain 5,000 events
  and use insertion order so clock changes do not reorder history.
- `Sources/RunEventuallyVerification`: end-to-end verification executable.
- `Tests/RunEventuallyCoreTests`: Swift Testing tests.
- `scripts`: verification and local app packaging.

The intended architecture has one per-user LaunchAgent scheduler, with the UI and
a local MCP adapter communicating through a shared API over XPC. Startup
registration through SMAppService, XPC, MCP, general command/schedule editing, and browser-assisted
authentication are not implemented yet. The prototype CLI writes task definitions
directly to SQLite; the desktop reads it and transactionally queues manual runs,
changes task/global pause preferences, and requests an active-run stop.
Only the scheduler launches commands. Keep scheduling authority centralized
when introducing the service.

Standard network/VPN, SSH, Smallstep certificate, and BigQuery providers are configured with `add-check`.
All standard checks and the legacy custom check must pass before launch. Provider
results distinguish Waiting, Action required, and Check error. The app presents
due, unstarted work as Queued (with Waiting on individual checks). The status
pill shows a compact countdown to the next readiness check or future schedule.
Pills have no hover/click action; details explain timing and scheduling holds;
per-check observations on pending runs support
pills without inferring success for unvisited checks. Raw probe output
must never enter Activity or run logs. Standard checks inherit the task context,
back off on failure, and can be rechecked without queuing a new run. Readiness
concerns environmental availability; assume the task already works manually.

`examples/pe-dashboard` provides standard checks plus an ADC-only custom check
and a daily pipeline configuration. Its original composite mode remains for older
definitions; do not reintroduce SSH polling for Smallstep-managed hosts. `scripts/install-dev-agent.sh` is a temporary per-user LaunchAgent
bridge for development; it is not the planned bundled SMAppService integration.
Run the example's Python unit tests when changing its readiness checks.

macOS is the only current target. Keep implementation in Swift. Cross-task
dependencies belong in creator-supplied scripts or Make targets rather than a
workflow graph in this app. General interactive terminal sessions are deferred.

## Scheduling invariants

- A scheduled time makes work due; failed prerequisite checks retain pending work.
- Coalesce missed daily occurrences into one pending run, preserving the first
  and last due times and occurrence count.
- Persist cursor advancement and due work in one transaction.
- Never overlap executions of the same task. Only one scheduler owns a database.
- Preserve the schedule cursor while paused so resuming catches up. Global pause
  is persisted separately from task pause; resuming globally preserves task pauses.
  Revalidate global pause inside the transactional claim, including when a pause
  arrives during a readiness probe. Pause lets running commands finish.
- New daily schedules start at creation; explicitly overdue one-time tasks run
  on the next reconciliation.
- Daily schedules use fixed IANA time zones. Repeated local times run once at
  the first occurrence; nonexistent times move to the first valid instant.
- Do not silently retry failed or ambiguous executions. Interrupted starting or
  running records become `outcomeUnknown` and hold subsequent work for review.
- Do not claim exactly-once external effects or verified process-tree recovery.
- Keep executable and arguments separate; shell interpretation must be explicit.
- Display due, started, and finished timestamps with clear labels and time zones.

Current limitations: one execution worker, minute polling, one custom check per
task, and complete stdout/stderr files with bounded legacy previews in SQLite.
The one-hour execution timeout uses continuous elapsed time including sleep.
Stop/timeout signals a verified isolated local process group with a one-second
cleanup period, then forces remaining group members to exit. Unverified groups
fall back to stopping the parent; detached descendants and remote work are not
covered. This is not restart-safe reconciliation of arbitrary external effects. Browser sign-in must eventually be user initiated, with credential
readiness rechecked afterward; do not automatically launch browsers from polling.

## Build and verify

From the repository root:

```sh
scripts/verify.sh
scripts/build-dev-app.sh
scripts/dev.sh
```

Verification runs the Swift tests and end-to-end checks. The scripts accommodate
the current Mac's Command Line Tools SDK/compiler mismatch and Swift Testing
framework paths; prefer them over ad hoc build flags. The build script produces
an ad-hoc signed development app at `.build/RunEventually.app`; this is not a
notarized distribution build.

The scheduler currently runs separately:

```sh
.build/RunEventually.app/Contents/MacOS/run-eventually serve
```

Prefer `scripts/dev.sh` for iterative development: it builds and updates the
development LaunchAgent and preview window together, verifies the running helper
digest, and waits for active work to drain. SIGTERM/SIGINT stop new admissions and
wake idle waits; already admitted operations finish before the scheduler exits.
Do not replace this with `launchctl kickstart -k` or stop active task children as
part of a development upgrade. An explicitly requested Stop run is a separate
operation handled by the scheduler; it must not automatically retry remote work.
Legacy helpers require an idle-only first upgrade. `scripts/test-dev-restart.py`
tests subprocess shutdown and restart safety; `--launchd` opts into temporary
LaunchAgent tests, using an isolated label and database.

For manual tests, use a temporary database with `--database PATH` or
`RUN_EVENTUALLY_DB`. The desktop accepts `RUN_EVENTUALLY_DB` when launching its
executable directly. Default state is in
`~/Library/Application Support/RunEventually/state.sqlite`.

Use harmless commands for manual execution tests. Verify scheduler changes with
deterministic schedule tests and subprocess integration checks as appropriate.
Actual login, sleep/wake, and authentication behavior needs installed-app testing;
do not equate simulated catch-up with verified macOS lifecycle integration.

## Working conventions

Keep changes focused and update usage documentation when behavior changes.
Avoid adding generated `.build` output, local databases, credentials, tokens, or
authentication output to Git. Describe implemented behavior and remaining limits
accurately. Run relevant checks before committing; build the development app for
SwiftUI changes. Commit and push only when requested.
