# launchd GetJob regression (op-425)

`launchd_getjob_test:named_job`: expected FAIL before the handler fix on
`mach-fixes-1` (`903c8fc2`), PASS after it. It submits two distinct dormant jobs,
requests each by its label through `launch_msg`, and checks the returned `Label`.
The old MIG handler exports the caller's job, so the named-job assertion fails.
A missing-label request must remain an errno reply. Cleanup removes only this
case's recorded job labels. No jobs have RunAtLoad or KeepAlive set.

The test requires root and a running launchd in a disposable rmxOS guest.
It loads `/usr/lib/liblaunch.so.5` inside its body and requires a nonzero
`bootstrap_port`, ensuring the MIG path reaches `ipc_process_msg`, rather than
the older socket handler that already exports the correct job. ATF `-l` only
lists metadata and never loads liblaunch. No expected-failure annotation hides
the before result. No guest result is recorded by this op.
