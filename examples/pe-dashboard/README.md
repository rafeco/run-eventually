# Morning dashboard pipeline

This development example schedules `/usr/bin/make pipeline` in `~/pe-dashboard`
daily at **06:30 America/New_York**. The job usually takes about 15 minutes; the
current runner has a one-hour timeout. Missed daily occurrences coalesce into
one run when the scheduler next runs and all readiness checks pass.

The pipeline performs BigQuery ETL, downloads data, runs data quality checks,
generates LLM summaries, uploads `experiments.db`, and restarts production. It
uses existing dashboard code without modifying its Makefile.

## Readiness

The task uses the scheduler's standard checks for:

1. The production SSH endpoint `10.248.22.135:22` is reachable.
2. BigQuery metadata access to `etsy-data-warehouse-prod:etsy_atlas` through the
   task's `bq` credential context.
3. The local Smallstep SSH agent has an unexpired user certificate for the configured subject and principal. Polling never connects or starts SSO.

`check.py --adc-only` retains the two conditions not yet covered by standard
providers: ADC credentials for the Makefile's auth check and Python ADC refresh
using the dashboard's actual credential configuration. It does not repeat the
standard network, Smallstep certificate, or BigQuery checks. Without that flag, the script retains
its original composite behavior for older task definitions.

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
  ~/run-eventually/examples/pe-dashboard/check.py --project-dir "$PWD" --adc-only
```

The CLI retains Ready, Waiting, Action required, and Check error categories;
the app shows neutral Waiting and check pills, with instructions in Waiting details. The remaining
custom check displays safe blocker messages for 13 (ADC) and 14 (Python ADC).
Raw auth output is discarded. Update an existing task's checks with
`configure-check.sh TASK_ID`; adding an equivalent standard check reuses its ID.
The script preserves the task's enabled/paused setting but does not pause it
while attaching checks. Pause the task first for a live migration, attach
replacements before removing old checks, then restore its original pause state.
Checks remain bounded.

For Google authorization, sign in explicitly in Terminal:

```sh
gcloud auth login
cd ~/pe-dashboard
make auth
```

The referenced pipeline checks ADC with `print-access-token`; its "Run: make
auth" output is advice on failure, not an invocation of that target. A successful
check does not prevent session expiry during a longer run. Both dashboard examples
use default ADC unless their execution context overrides it. See the skill's
[Google renewal guidance](../../skills/run-eventually/references/readiness.md#google-credential-renewal)
for shared CLI/ADC sign-in and credential-scope considerations.

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

The configuration script defaults Smallstep subject to `$USER@etsy.com` and
principal to `$USER`; override `SMALLSTEP_SUBJECT` and `SMALLSTEP_PRINCIPAL` for
another identity. Renew expired SSH certificates through your normal interactive
login. Certificate validity does not prove remote authorization.
