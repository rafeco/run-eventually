# Executive metrics dashboard

Run Eventually refreshes `~/product-metrics-dashboard` locally each day, uploads
only a consistent snapshot of `metrics.db`, and serves it on SSH host `vm` from
`~/exec-metrics-dashboard`. Google CLI and ADC authorization stay on the Mac.

Configure with `bash examples/exec-metrics-dashboard/configure.sh`. Defaults to
06:30 America/New_York; set `EXEC_METRICS_TIME=HH:MM` or `EXEC_METRICS_DIR` to
override before configuration. Setup creates the task paused, attaches readiness
checks, then enables it. Repeated setup leaves the existing task unchanged.

The job runs `make datamart-etl` then `make refresh` locally. After both succeed,
it takes a SQLite backup, checks integrity, uploads a unique staging filename,
and verifies its SHA-256 and integrity on the VM. It stops only the dedicated
`exec-metrics-dashboard` tmux session, checkpoints the old database, retains it
as `metrics.previous.db`, replaces the database, starts the existing virtualenv's
Python directly, and checks `/healthz`. Startup failure restores the previous DB
and attempts to restart it. An unmanaged listener on port 8088 blocks deployment;
stop the manually launched dashboard before the first scheduled deployment.

Inspect with `ssh vm 'tmux attach -t exec-metrics-dashboard'` and
`ssh vm 'tail -50 ~/exec-metrics-dashboard/dashboard.log'`. The task does not pull
code, sync dependencies, start a stopped VM, or perform Google login. Readiness
waits for local Google credentials, noninteractive SSH, and the VM runtime. Run
`sshvm` yourself if the VM needs starting, and authenticate locally as prompted
by Run Eventually. The existing scheduler LaunchAgent must remain running.

The scheduler allows one hour per run and does not automatically retry failed
or ambiguous runs. Only the parent is terminated on timeout; inspect lingering
ETL/upload processes before rerunning. The 1.9 GB database requires temporary
space locally and space for staging plus the previous DB on the VM. An interrupted
upload can leave `.metrics-*.db` files on the VM. The app log needs manual retention.
This procedure is not a multi-writer database deployment; don't run VM ETL at the
same time. Code/schema compatibility must be maintained between the checkouts.
