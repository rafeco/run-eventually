# Morning dashboard pipeline

This development example schedules `/usr/bin/make pipeline` in `~/pe-dashboard`
daily at **06:30 America/New_York**. The job usually takes about 15 minutes; the
current runner has a one-hour timeout. Missed daily occurrences coalesce into
one run when the scheduler next runs and all readiness checks pass.

The pipeline performs BigQuery ETL, downloads data, runs data quality checks,
generates LLM summaries, uploads `experiments.db`, and restarts production. It
uses existing dashboard code without modifying its Makefile.

## Readiness

`check.py` runs in the dashboard's existing Python environment and requires:

1. The production SSH endpoint `10.248.22.135:22` is reachable.
2. Google CLI credentials can obtain a token for the `bq` steps.
3. ADC credentials can obtain a token for the Makefile's own auth check.
4. Python ADC can refresh using the dashboard's `.env` configuration.
5. SSH can authenticate with no terminal interaction or host-key prompt.

Google CLI credentials and ADC are separate configurations; see
[Google's authentication guide](https://docs.cloud.google.com/sdk/docs/authenticate).

The endpoint check establishes reachability, not the identity of a VPN. Tokens
and raw auth errors are discarded. No check launches a browser, uploads data,
starts a BigQuery job, or restarts production. Readiness does not prove all API
permissions, remote sudo permissions, LLM availability, or that credentials will
remain valid for the full run.

Run the check manually to see an actionable explanation:

```sh
cd ~/pe-dashboard
/opt/homebrew/bin/uv run --no-sync python -B \
  ~/run-eventually/examples/pe-dashboard/check.py --project-dir "$PWD"
```

The app displays a configured, safe blocker message for each exit code: 11 for
network, 12 for CLI credentials, 13 for ADC, 14 for Python ADC, 15 for SSH, and 2
for local setup. It shows the last unsuccessful check time. Raw auth output is
discarded. Update an existing task's mapping with `configure-check.sh TASK_ID`.
Each CLI/SSH check is bounded, with a 60-second overall scheduler check timeout.

For Google authorization, sign in explicitly in Terminal:

```sh
gcloud auth login
cd ~/pe-dashboard
make auth
```

For SSH, connect and renew work SSH credentials using the normal company process.
Test `ssh -o BatchMode=yes 10.248.22.135 true` afterward. Approve a first-time host
key in Terminal only after verifying it normally. This example honors the existing managed SSH host-verification settings. Its `bin/ssh` and `bin/scp` wrappers enforce batch mode during
the pipeline, so unattended work fails rather than waiting for a password.

## Configure and start

From the Run Eventually repository:

```sh
scripts/build-dev-app.sh
examples/pe-dashboard/configure.sh
scripts/install-dev-agent.sh
open .build/RunEventually.app
```

Configuration uses the default scheduler database (or `RUN_EVENTUALLY_DB` if set).
It creates the task paused, attaches the check, then enables it. Repeating setup
does not create another task with the same name; it leaves an existing task alone.
Use `PE_DASHBOARD_DIR` to override the dashboard directory. Inspect `list` and use
`pause TASK_ID` to disable future starts.

The development agent always uses the default database, copies the CLI to
`~/Library/Application Support/RunEventually/development/run-eventually`, and
registers `com.rafeco.RunEventually.development` as a per-user LaunchAgent. It
starts at login, restarts on exit, and polls every minute. The app can close
without stopping it. Logs are under `~/Library/Logs/RunEventually` and currently
need manual retention management. It does not provide the planned SMAppService
registration UI; remove this bridge before enabling a future bundled service.

To inspect or stop the development agent:

```sh
launchctl print "gui/$(id -u)/com.rafeco.RunEventually.development"
launchctl bootout "gui/$(id -u)/com.rafeco.RunEventually.development"
```

Stopping the scheduler during execution can leave child processes alive and
marks the run's outcome unknown on restart. Stop it while idle; do not manually
rerun an ambiguous pipeline until its old processes and external effects have
been checked. Failed pipelines are not automatically retried. A later daily
occurrence creates new work.

## Verification

```sh
scripts/verify.sh
/usr/bin/python3 -B examples/pe-dashboard/test_check.py
```

The preflight unit tests simulate blocked credentials, blocked network, SSH
failure, and readiness. Actual end-to-end acceptance still requires a successful
pipeline, a real sleep/wake catch-up, and testing SSH credentials in the login
service environment. The initial live probe on October 4, 2026 reached port 22
but found Google CLI authorization and noninteractive SSH unavailable.
