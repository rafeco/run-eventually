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
- `Sources/RunEventuallyDesktop`: read-only task status, history, and logs.
- `Sources/RunEventuallyVerification`: end-to-end verification executable.
- `Tests/RunEventuallyCoreTests`: Swift Testing tests.
- `scripts`: verification and local app packaging.

The intended architecture has one per-user LaunchAgent scheduler, with the UI and
a local MCP adapter communicating through a shared API over XPC. Startup
registration, XPC, MCP, UI editing, reusable VPN/Google checks, and browser-assisted
authentication are not implemented yet. The prototype CLI writes task definitions
directly to SQLite; the desktop reads it. Keep scheduling authority centralized
when introducing the service.

macOS is the only current target. Keep implementation in Swift. Cross-task
dependencies belong in creator-supplied scripts or Make targets rather than a
workflow graph in this app. General interactive terminal sessions are deferred.

## Scheduling invariants

- A scheduled time makes work due; failed prerequisite checks retain pending work.
- Coalesce missed daily occurrences into one pending run, preserving the first
  and last due times and occurrence count.
- Persist cursor advancement and due work in one transaction.
- Never overlap executions of the same task. Only one scheduler owns a database.
- Preserve the schedule cursor while paused so resuming catches up.
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
task, bounded output stored in SQLite, and timeout termination of the parent
process only. Process-group termination and reliable recovery of spawned children
still need work. Browser sign-in must eventually be user initiated, with credential
readiness rechecked afterward; do not automatically launch browsers from polling.

## Build and verify

From the repository root:

```sh
scripts/verify.sh
scripts/build-dev-app.sh
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
