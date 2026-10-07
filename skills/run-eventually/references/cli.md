# Development CLI

Run `help` on the selected executable first. This describes the current preview;
the executable's supported commands take precedence if they differ.
Below, `cli` is the resolved absolute executable path, `project` is the target
project's absolute directory, and `task_id` is the returned ID. These are shell
variables, not literal CLI arguments.

## Commands

```sh
"$cli" help
"$cli" list
"$cli" runs
"$cli" activity

"$cli" add-daily 07:00 America/New_York project-refresh --paused \
  --cwd "$project" \
  --env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  -- /usr/bin/make refresh

"$cli" set-check "$task_id" --timeout-seconds 10 \
  --failure-message '1=Required connection or credentials are unavailable' \
  --cwd "$project" \
  --env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  -- /absolute/path/to/readiness-check

"$cli" resume "$task_id"
"$cli" pause "$task_id"
"$cli" run-now "$task_id"

"$cli" add-once 2030-01-15T09:00:00-05:00 project-once \
  --cwd "$project" -- /usr/bin/make refresh
```

Replace sample names, times, paths, and targets with the user's request. Verify
`PATH` against installed tools; Homebrew is not required. For explicit database
selection, insert `--database "$database"` immediately after `"$cli"` on every
call. `RUN_EVENTUALLY_DB` also selects state.

Checks return 0 for ready, 1 for blocked, and another code for a check error. All
nonzero exits, launch errors, and timeouts prevent execution. Failure messages map
nonzero codes to safe explanations. Only one check can be attached; `set-check`
replaces it. Preserve all conditions still needed when changing an existing check.

## Inspection

`list` shows ID, name, paused/enabled state, and pending count. `runs` shows run ID,
state, first due timestamp (UTC), occurrence count, and blocker; it does not show
the owning task ID. Neither prints a complete task definition.

Use the desktop where it exposes the needed fields. For CLI verification and
duplicate detection, inspect preview SQLite JSON payloads locally through a
read-only connection. Never write state with SQL or dump raw environment values
or unrelated logs. This example selects the relevant definition:

```python
import json
import sqlite3
from pathlib import Path

# Supply these from the resolved database and task name or returned ID.
database = Path(database_path).expanduser().resolve()
with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
    for (payload,) in connection.execute('SELECT payload FROM tasks'):
        task = json.loads(payload)
        if task['id'] != requested_id and task['name'] != requested_name:
            continue
        for spec in (task['command'], (task.get('check') or {}).get('command')):
            if spec is not None:
                spec['environment'] = {key: '[redacted]' for key in spec['environment']}
        # Review arguments for secrets before displaying this result.
        print(json.dumps(task, indent=2))
```

For one task's run status, query `runs` by `task_id` with a bound parameter,
selecting only `id` and `state` when logs are unnecessary. JSON date fields use
Swift's reference date (2001-01-01 UTC), not Unix time.

## Limits

- Only one-time and daily schedules are implemented. There is no weekly/cron,
  task deletion, general command/schedule editing, cancellation command, or
  unknown-outcome resolution command. Pause disables future launches; it neither
  deletes a task nor stops running work.
- Idempotency keys and revision checks are not implemented. Inspect after an
  uncertain creation result before retrying; do not promise duplicate prevention.
- `add-once` has no paused option and attaching a check is a separate write.
  An overdue task can launch before its check is attached. For a future request,
  finish and verify setup before its due time. If already due, or setup cannot
  finish safely in time, explain the limitation and resolve the configuration
  with the user. Do not silently shift the requested time, stop the live
  scheduler, or claim atomic creation.
- `run-now` requires an enabled task, respects checks and unknown outcomes,
  reuses existing pending/active work, and preserves the recurring schedule.
- Scheduling polls about once a minute. Durable creation does not prove the
  scheduler is running. `tick` can execute due work from the whole database;
  reserve it for authorized execution or isolated tests.
- The preview stores bounded command output in SQLite. Commands and checks
  should produce safe summaries. Browser-assisted sign-in and arbitrary
  interactive input are not implemented; users authenticate independently.
