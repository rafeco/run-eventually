# Run Eventually

A lazy scheduler for macOS.

A macOS app for scheduled commands that wait until their prerequisites are ready,
including after sleep or downtime.

See the [design document](docs/design.md) for the proposed architecture, scheduling
behavior, user-assisted authentication, and implementation milestones.

The first working slice has a persistent command scheduler, one-time and daily
schedules, custom prerequisite commands, a command-line interface, and a read-only
SwiftUI status window. It catches up after the scheduler starts again and combines
missed daily occurrences into one pending run. It conservatively holds a run for
review if the scheduler stops during command execution.

Build a local preview app with `scripts/build-dev-app.sh`, then open
`.build/RunEventually.app`. Start its scheduler separately with:

```sh
.build/RunEventually.app/Contents/MacOS/run-eventually serve
```

Tasks can currently be added from the command line. For example:

```sh
.build/RunEventually.app/Contents/MacOS/run-eventually \
  add-daily 06:30 America/New_York daily-report \
  --cwd /absolute/path/to/project -- /usr/bin/make daily-report
```

Use `run-eventually help` for the remaining commands, including `set-check`,
`pause`, `resume`, `runs`, and `tick`. Run `scripts/verify.sh` for the test suite
and end-to-end checks.

This is a development preview. Automatic login startup, task editing in the app,
reusable VPN and Google Cloud checks, browser-assisted sign-in, MCP, and signed
distribution are still to be built.

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
