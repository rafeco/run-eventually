---
name: run-eventually
description: Create and manage Run Eventually tasks for local macOS commands that should run once or daily and wait for prerequisites, including after sleep or downtime. Use when the user names Run Eventually or wants to schedule a project's scripts, Make targets, or data refreshes with it.
---

# Run Eventually

Turn the user's scheduling request into a persistent command task. Accepted work
survives the agent session closing; execution requires the Mac to be awake and the
background scheduler running.

## Find the interface

Use connected Run Eventually MCP tools if actually available, following their
current schemas. The preview has a CLI; MCP is planned, not required. Read
[references/cli.md](references/cli.md) before using the CLI fallback.

Find the executable without assuming this session is in the scheduler's repository:

1. Use a user-supplied path or `RUN_EVENTUALLY_CLI` if set. That variable is this
   skill's discovery convention, not an option implemented by the CLI.
2. Check `command -v run-eventually`, then `RunEventually.app` under `/Applications`
   or `~/Applications`, using `Contents/MacOS/run-eventually` inside the bundle.
3. Check `~/Library/Application Support/RunEventually/development/run-eventually`.
4. If using this skill from a Run Eventually checkout, check its
   `.build/RunEventually.app/Contents/MacOS/run-eventually`. Otherwise use a
   repository location already supplied by the user or session context.

Validate the candidate with `help`. If missing, explain that the skill does not
install the scheduler and request its location or installation. Do not crawl the
home directory or build a guessed checkout.

Resolve the database before any command: honor an explicitly supplied database or
`RUN_EVENTUALLY_DB`; otherwise use
`~/Library/Application Support/RunEventually/state.sqlite`. Keep every operation
on the same database. Never silently replace test state with live state.

## Configure the task

- Read the target project's instructions and existing scripts or Make targets.
  Prefer a maintained entry point over duplicating its pipeline in the skill.
- Use absolute executable and working-directory paths. Keep arguments separate;
  use a shell only when its interpretation is required.
- Supply the background process's required environment, especially `PATH` for
  tools such as `uv`, `bq`, and `gcloud`. The agent's shell environment is not the
  scheduler's environment. Keep credentials in existing local configuration;
  avoid copying secret values into definitions or displayed commands.
- Resolve time using the user's date and zone context. Daily schedules need an
  IANA zone; one-time schedules need a timestamp with an offset. Clarify missing
  times or ambiguous zones that context cannot resolve. Do not substitute daily
  scheduling for a requested weekly or interval schedule.
- Name the task recognizably with its project and operation. Inspect existing
  definitions before creation; compare directory, command, arguments, schedule,
  and check as well as name. Reuse an equivalent task. Investigate same-name tasks
  with different settings rather than blindly adding another.
- Attach short, noninteractive readiness checks for required credentials or
  network access. Multiple conditions can live in one project-owned composite
  check. Check the credential source the command actually uses: Google CLI
  credentials and ADC differ. Checks must not launch login or print tokens.

A request to schedule work authorizes ordinary task creation; do not add a routine
confirmation step. Ask only for necessary missing information. Do not execute the
project's command immediately unless requested or already authorized. Test this
skill with harmless commands and an isolated database.

## Save and verify

For daily tasks with checks, create with `--paused`, attach the check, verify the
saved configuration, then resume unless the user requested a paused task. If setup
fails, leave it paused and report incomplete setup. The CLI cannot atomically
attach a check to a one-time task; follow the reference's limitation.

Capture the returned ID. If creation's outcome is uncertain, inspect state before
retrying: the CLI has no idempotency keys. List-based checks do not guarantee
uniqueness across simultaneous agent sessions.

Verify the saved definition and enabled/paused state. Separately check scheduler
availability. For the current development LaunchAgent, the read-only command
`launchctl print "gui/$(id -u)/com.rafeco.RunEventually.development"` checks that
installation only, not every possible scheduler process. Report health as
unverified when it cannot be established. Do not start another `serve` or use
`tick` on live state to test connectivity: they can execute unrelated due work.
Installing login startup is a separate operation.

For authorized immediate execution, use `run-now` and inspect status. Queuing does
not prove success. Pause does not stop an already running process. Failed runs
are not silently retried; unknown outcomes require review before another run.

Report name and ID, command and directory, schedule with zone, checks,
enabled/paused state, and blockers or unverified scheduler health. Distinguish
saved, queued, running, and succeeded. Explain catch-up when relevant: missed
daily occurrences coalesce into one pending run rather than replaying every day.
