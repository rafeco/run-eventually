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
