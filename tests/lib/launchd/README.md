# Launchd consumer regressions

These tests run against the launchd that is PID 1 in the guest. Test-only
projections expose private objects and the demand callback; Zig owns fixture
scheduling, Mach operations and observations. The projections are included
only in the test build, in both base and fixed images.

The demand case removes a real imported job after the kernel has returned its
member's nonempty receive status, before launchd looks up that member's job.
This isolates the stale lookup without relying on scheduling delays.
The fixture puts that member first in the actual returned membership snapshot
so unrelated boot-time demand cannot end the scan before it. It also observes
that the subsequent job lookup returns NULL.

The drain cases observe the real `mach_msg` calls made by launchd. A test-only
receive limit ends a faulty baseline loop; hitting that limit is an observed
failure, never a successful drain. The fixed cases must finish without it.
Successful receives record message identifiers, so a receive count alone
cannot conceal duplicate or missing messages. Allocation observations check
the two drain buffers are released.

The late dead-name case receives a real notification after removing the job,
then passes it to launchd's existing notification handler. It observes the
notification's extra dead-name uref and an unrelated owned right before and
after handling. That unrelated right belongs to another real idle job; its
record, launch count and PID must remain unchanged.

Each crash job invokes the test executable with `--crash-job`, which calls
`raise(SIGABRT)`. Its messages were queued before launchd starts it. The real
reaping path must set `j->crashed` and enter the drain; the observed terminating
signal is checked. Launchd's crash definition remains unchanged.

In the base test build, the callback invocation fixture records an attempted
NULL call and returns, preserving PID 1 so the remaining observations can be
collected. The fixed lookup check must skip the invocation entirely. The test
does not claim to demonstrate a natural PID-1 crash on base.

The fixed-only `close_unregistered` case allocates a real receive name beyond
the current callback table, joins it to the demand set without registration,
and observes detach before close and the final invalid name. It is not run on
base: its unchecked table write could corrupt PID 1 and prevent later cases.
It also checks that a receive right already outside every set is closed.
The invalid-name receive right is destroyed at real drain entry, after job
launch and reaping. Completed drain-name mappings are retired before another
job is created, so reused names cannot be attributed to an earlier drain.
Invalid-name setup detaches the member before destroying its receive right,
so the drain error probe does not also depend on port-set destruction ordering.
