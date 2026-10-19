# Readiness checks

The task is assumed to work manually. Scheduling checks determine whether the
environment permits it to run now. Do not expand scheduling into an application
setup audit or scan `.env` for API keys. If a required static setting is known to
be wrong, report the setup change rather than polling it as a dependency.

## Standard provider scope

The current CLI provides these standard checks. Prefer them over writing a
custom shell script for the same condition. Confirm support with `help` when
using an older installation or a different MCP schema.

| Provider | Choose it for | Configuration |
| --- | --- | --- |
| Network / VPN | A private endpoint must be reachable. | Host and port; use the task's destination rather than VPN-app status. Reachability does not prove a specific VPN connection. |
| SSH | The task needs noninteractive remote access without login hooks. | Existing host alias and execution context; preserve SSH settings and host verification. |
| Smallstep | Existing SSH-agent user certificates must be usable without SSO polling. | Certificate subject (agent identity comment) and SSH principal; requires `step` and the task's `SSH_AUTH_SOCK`. Checks validity with a 60-second expiry margin locally. |
| BigQuery | The task uses `bq` with credentials that can expire or become unavailable. | Project ID and optional dataset ID. Uses `bq` in the task's directory and environment; reads metadata without running a query. Listing datasets does not prove permissions to every dataset, and reading dataset metadata does not prove query permissions. |

Do not create a separate polling task for a prerequisite. All conditions must
pass before the scheduler starts the original task. Readiness is not a guarantee
that credentials or connections will remain available throughout execution.

For Smallstep/Okta SSH, use `smallstep` instead of `ssh`, plus `network` if
endpoint reachability matters. Generic SSH can execute `ProxyCommand` or `Match
exec` helpers that launch SSO even with BatchMode. Do not use `ssh -G` to discover
these settings: it can also run Match hooks. Inspect configuration files directly.
The Smallstep check only runs `step ssh list --raw SUBJECT` and `step ssh inspect
--format=json` on temporary local public certificate files. It never requests a
certificate, renews one, contacts a CA, connects to a host, or launches login.
Missing/expired certificates, a missing agent, or a wrong principal need user
action: renew through the normal interactive SSH login, then recheck. Inspection
failures are check errors. A valid local certificate does not prove that the remote
host trusts its CA or grants access; execution establishes that. Do not retain
custom SSH probes alongside this check, since those can still trigger SSO.

## Explain blockers

- **Waiting:** a transient condition such as an unreachable endpoint or service
  timeout. The scheduler retains the run and rechecks.
- **Action required:** evidence of an expired login, rejected SSH credentials,
  denied access, or a known configuration defect. Describe the specific change;
  a fix made outside the app can be discovered by a later check.
- **Check error:** an inconclusive probe. Do not label every nonzero exit or
  network failure as an authentication problem.

These are readiness categories, not failed task attempts. “Action required” does
not mean permanently failed. Rechecks never authorize automatic login, host-key
acceptance, or changes to credentials.

## Configure and inspect

Create a daily task paused, attach its required checks, verify them, then resume.
The standard checks inherit the task's working directory and environment,
including PATH and credential configuration. Do not add a check for a different
credential source merely because it is installed on the Mac.

```sh
"$cli" add-check "$task_id" network --host internal.example --port 22
"$cli" add-check "$task_id" ssh --host work-vm
# For Smallstep-managed hosts, use this instead of the SSH check:
"$cli" add-check "$task_id" smallstep --subject person@example.com --principal person
"$cli" add-check "$task_id" bq --project work-project --dataset metrics
"$cli" checks "$task_id"
"$cli" check-now "$task_id"
```

Replace the sample targets with the task's actual dependencies; do not attach
every provider automatically. `vpn` is an alias for `network`, not detection of a VPN app.
Network, SSH, and Smallstep default to 10 seconds; BigQuery defaults to 30. Override with
`--timeout-seconds N` (positive, at most 120 seconds).

`add-check` preserves existing checks and returns the existing ID for an exact
provider/configuration/timeout match. All attached standard checks and the legacy
custom check, if present, must pass. `checks` lists check IDs and configurations.
`remove-check TASK_ID CHECK_ID` removes a specific standard check;
`remove-check TASK_ID custom` removes the legacy custom check. When migrating,
attach the standard replacement before removing the custom check, and preserve
any other conditions it enforced.

`check-now` probes readiness without launching the task or changing its schedule;
exit 2 means a condition did not pass. It does run an attached custom check.
`recheck TASK_ID` clears a pending run's backoff so the scheduler rechecks on its
next scan, without creating a new run. The app offers the same Recheck action.

Waiting and inconclusive standard checks retry after 1, 2, 4, 8, then at most 15
minutes. Action required rechecks every 5 minutes to discover external fixes.
Check edits invalidate backoff. The CLI and Activity retain the blocker category;
the app labels pending work Queued, with Waiting on individual check pills and
collapsed blocker details. The status pill shows a compact next-check countdown;
Queued work details show the full attempt time. This is not a promise that task
execution will start then.
Per-check pills reflect the current scan; later checks skipped after a blocker
remain Not checked. These results do not promise continued credential validity.

Use one custom check only for an environmental condition not covered by the
providers, such as the ADC credential source a Python task actually uses. Custom
exit 0 means ready, exit 1 means waiting, and other exits or timeout mean check
error; the scheduler cannot infer action required from a legacy exit code alone.

## Google credential renewal

Google CLI credentials (`gcloud`/`bq`) and Python ADC are distinct, even when they
use the same account. Match the task's credential source, including configured
paths and project overrides. A CLI token check alone does not prove Python ADC
can refresh. The existing dashboard examples retain a Python ADC refresh check
for this reason; the BigQuery provider checks the `bq` credential context.

For a user who wants to renew both default sources, `gcloud auth login --update-adc
--force` writes CLI credentials to ADC too. It overwrites the existing default ADC
configuration; preserve task-specific account, scopes (including Drive access),
and impersonation requirements rather than prescribing it for every task.
Use the user's existing explicit login process for separate credential profiles.
Login is user initiated, never part of polling or an automatic failed-run retry.
[Google CLI login](https://docs.cloud.google.com/sdk/gcloud/reference/auth/login)

Readiness can pass and authentication can subsequently require renewal. Google
Workspace session controls can expire local ADC independently of a task finishing.
Compare check times and exact safe error categories before attributing that loss
to a preceding job. An error suggesting `make auth` is not evidence that the job
executed that target. Inspect the actual command chain; do not capture credential
values or raw authentication responses as evidence.
[Google reauthentication](https://docs.cloud.google.com/docs/authentication/reauthentication)
