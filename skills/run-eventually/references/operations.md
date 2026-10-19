# Status, pause, and recovery

Read this when inspecting an existing task, handling sleep or a quiet run, or
changing pause state. Confirm the selected executable's `help`; app controls do
not imply equivalent CLI commands exist.

## Interpret the app

- **Later Today** means the scheduled time has not arrived in the schedule's zone.
  It is a display status, not a queued run. Last successful run is separate history.
- **Queued** means due work is saved and has not started, including morning
  sign-in or network delay. Status pills show a compact countdown to the next
  readiness check (5m, < 1m); Later Today can show 1h 10m until the scheduled time.
  Pills are not interactive. Queued work details show full check timing. Pauses or an occupied
  worker explain the hold instead of promising an execution time. Read Waiting
  details for the actual readiness category and corrective action. Per-check
  Waiting labels do not mean that the run is missing from the queue.
- Sidebar check pills appear only for pending work. Passed results belong to the
  current scan; Not checked means a prior blocker prevented reaching that check.
  Running older records may show Passed in details based on admission, without a
  stored individual result. Do not treat that as a live credential check.
- Failed/Cancelled means an execution attempt ended. Read its reason and logs;
  a previous failure does not establish that a newer pending run has failed.

## Pause scope and authority

`pause TASK_ID` and `resume TASK_ID` change one task. The app also provides Pause
task/Resume task and Pause all/Resume all. Global pause persists across restarts,
prevents new scheduling and launch, and preserves catch-up. Global resume leaves
individual task pauses intact. Pause lets running commands finish.

The CLI has no global-pause or active-run-stop command. Use the app or an actually
available connected interface exposing those operations; never invent commands
or write scheduler control state with SQL. Do not resume a global or individual
pause simply to make newly scheduled work run when the user intended that pause.
An enabled task can remain held by global pause, so verify both where possible.

The Tasks status bar distinguishes a stopped scheduler, a service draining for
restart, and a build mismatch. A mismatch alone does not prove scheduling paused.
An older service may not honor a newly saved global pause until its update starts;
report that pending capability rather than claiming the pause is already effective.
For development upgrades, use the repository's restart script when available and
within scope. It stages the helper, drains admitted work, and verifies the running
build. Do not force-kill active work to complete an upgrade. Do not start a second
scheduler or invoke live `tick` as a health check.

## Sleep, stop, and retry

The preview's fixed one-hour command deadline includes sleep. Waking during
execution is recorded; a deadline crossed during sleep is enforced on resume.
The UI shows elapsed time and last output age, with Running · Quiet after two
minutes without output and Possibly stalled after ten minutes. These thresholds
apply without requiring sleep; wake events never count as progress or reset the
quiet timer. Run details show an approximate deadline countdown. Pending tasks
state that they have not started and can explicitly identify waiting for the
single worker rather than a credential check. Silence alone does not prove a hang: a remote query or a program buffering its output
can be legitimate. Inspect the run's log timestamps, current command, and any
remote job status before diagnosing a stall.

Stop run is a separate app control for the updated scheduler. It requests a
short cleanup period, then forces remaining processes in the verified isolated
local process group to exit. If isolation is unverified, only the parent is
signaled. Detached descendants and remote jobs may remain. The run retains its
logs and becomes Cancelled; timeout records Failed. No automatic retry occurs.

After authorized stopping or a timeout, verify termination and inspect external
work before an authorized Run now retry. Recheck only probes pending readiness;
it does not retry a terminal failure. Scheduler interruption still yields
Outcome unknown, which blocks subsequent work. The current UI/CLI cannot resolve
that state; do not relabel it as Failed or retry by editing the database.
