# Mach fix regressions

## Batch 3 (op-426)

Continuation op-427 adds `mach_lifetime_test` before the lifetime fixes:

| Case | Finding | Expected on `ee883a74` | Expected after step 3 |
| --- | --- | --- | --- |
| `inherited_rights` | op-389 #4 | FAIL: child exit retains its bootstrap send right | PASS: send count returns to baseline |
| `shared_fd_exit` | op-389 #11 | FAIL: shared-table child cannot use the parent's Mach name | PASS: both use the name; child exit leaves it intact |
| `task_control_death` | op-392 F2 | FAIL: exited task's control port is still active | PASS: port is dead |
| `thread_control_death` | op-392 F2 | FAIL: control port remains active beyond 15 s | PASS: control port inactive within 15 s after reaping |
| `rfork_unshare` | op-430 in-place RFFDG | FAIL: old binding remains attached | PASS: fresh names; bootstrap retained |
| `rfork_clean_table` | op-430 in-place RFCFDG | FAIL: old binding remains attached | PASS: fresh names; bootstrap retained |
| `incarnation` | op-393 N5 prerequisite | FAIL: old task port remains active across later births | PASS: old port stays dead |

The fixture pins actual control ports and observes their Mach activity, or
observes the send-right count of a private bootstrap port. The shared-table
case checks Mach urefs, not numeric descriptor assignments. `incarnation`
holds an old capability through 64 later process lifetimes; it does not claim
to force a particular UMA slot to be reused. All expectations are
source-derived; no guest execution is claimed.

`mach_identity_test:live_credentials` covers op-392 F1: expected FAIL on
`mach-fixes-2` at `ee883a74`, PASS after the send-time credential fix. The
fixture calls live `ipc_kmsg_get` on the test's private user message and reports
its constructed trailer after effective uid/gid change. It never queues a
message or edits task credentials. This isolates the sender identity from the
separate receive-trailer/model work deferred to step 4. It is a source-derived
expectation; no guest result is claimed.

## Batch 2 (op-420)

`mach_entry_test:native_hold` expects FAIL on `mach-fixes-1` at `903c8fc2`
and PASS after separating Mach urefs from native file references. The fixture
holds one extra native file reference while calling `mach_port_get_refs` on a
new dead name. The expected Mach count is one; the unchanged backend reports
two. These are source-derived expectations, not guest observations.

`mach_entry_lock_test:close_lookup` covers op-389 #2 and op-392 S2's
entry cause: expected FAIL on `903c8fc2`, PASS after locked lookup and
descriptor revocation. A fixture holds the space read lock during lookup;
a second thread closes the name. It records whether close finished before
the transaction unlocked, without dereferencing a potentially freed entry.

`mach_entry_knote_test:destroy_detaches` covers op-392 S4: expected FAIL
on `903c8fc2`, PASS after normal descriptor removal detaches the knote.
It registers an empty port set, destroys the Mach name, then checks that
the kqueue has no remaining event from that destroyed set.

`mach_entry_dup_test:reject_aliases` expects FAIL on `903c8fc2` and PASS
after descriptor aliases are rejected with EOPNOTSUPP. Native pipe duplication
is a positive control, and the Mach receive right remains destroyable after
both rejected operations.

These are expected results, not guest observations. The Gatekeeper runs the
same test artifacts on unchanged alpha2 and the fixed image. No expected-failure
annotations hide alpha2 failures.

absolute and past run the clock syscall in a child observed through a pipe.
The parent bounds the observation to 2000 ms, kills and reaps a delayed child,
and emits ATF FAIL before the outer 15-second bound. Fixed expectations and
the absolute duration/wakeup checks remain unchanged.

| Fix | ATF program:case | alpha2 | after fix |
|---|---|---|---|
| 1 | mach_fileops_test:poll | PANIC | PASS |
| 1 | mach_fileops_test:nonblock | PANIC | PASS |
| 1 | mach_fileops_test:async_flag | PANIC | PASS |
| 1 | mach_fileops_test:chmod | PANIC | PASS |
| 1 | mach_fileops_test:chown | PANIC | PASS |
| 1 | mach_fileops_test:kevent_read | PANIC | PASS |
| 1 | mach_fileops_test:kevent_write | PANIC | PASS |
| 2 | mach_swtch_test:swtch_pri | PANIC | PASS |
| 2 | mach_swtch_test:swtch | PANIC | PASS |
| 3 | mach_short_kevent_test:short_buffer | PANIC | PASS |
| 4 | mach_dead_name_test:dead_name | PANIC | PASS |
| 5 | mach_named_pset_test:named_pset | PANIC | PASS |
| 6 | mach_translate_test:seeded_output | FAIL | PASS |
| 7 | mach_file_lifetime_test:success_eof | FAIL | PASS |
| 7 | mach_file_lifetime_test:fd_exhaustion | PANIC | PASS |
| 8 | mach_passable_test:reject_kqueue | FAIL | PASS |
| 8 | mach_passable_test:accept_pipe (positive control) | PASS | PASS |
| 9 | mach_proc_info_test:null_fd | PANIC | PASS |
| 10 | mach_filecaps_test:preserve_caps | FAIL | PASS |
| 11 | mach_timeout_test:milliseconds | FAIL | PASS |
| 12 | mach_clock_test:relative, absolute, past, invalid, interrupt | FAIL | PASS |
| 13 | mach_timebase_test:ratio, uptime | FAIL | PASS |

The Zig program links ATF's C ABI; registration and metadata-only `-l` do not
execute its syscall observations. Every case allocates its own receive right.
The poll error is POLLNVAL; the fcntl errors are ENOTTY; chmod, chown and native
read/write filter registration return EINVAL. The kevent cases require an
EV_ERROR receipt, not merely any event.

The fd_exhaustion assertion remains MACH_RCV_BODY_ERROR|MACH_MSG_IPC_SPACE
(0x1000600c). EMFILE means no room in the receiver's descriptor name space,
not a kernel allocation shortage. XNU ipc_kmsg.c:3640-3643,3669-3672 maps
KERN_RESOURCE_SHORTAGE to IPC_KERNEL and other copyout failures to IPC_SPACE;
ipc_object.c:847 names KERN_NO_SPACE for a full receiver space. The fix maps
EMFILE to KERN_NO_SPACE. PANIC/PASS expectations are unchanged.

Fix 6 uses a freestanding Zig test module in the disposable guest. Its C adapter
only projects kernel ABI fields and routes module/sysctl calls; all observation
logic is Zig. The output pointer starts equal to the valid object pointer, so
alpha2 deterministically reports owned=0 instead of depending on stack reuse.

Fix 9 calls the live Mach proc_pidbsdinfo routine through leak-locals on a
private proc snapshot with p_fd=NULL. It never edits a live process descriptor
table. The source kernel/module ABI is projected by the C adapter; the snapshot
setup, call and observed count are in the Zig fixture.

## op-437 teardown remediation

`mach_lifetime_test:failed_creation` routes the actual process ctor/dtor events
on a private, zeroed proc with an empty thread list. This is the state before
the first native thread allocation, which cannot be forced reliably from user
space. Only Mach registers these two events in this source tree. Expected on
`db592723`: PANIC (NULL first thread); after remediation: PASS (constructed=1,
attachment cleared). On batch-2 `ee883a74`: PASS, constructed=0, since that
branch has no per-process constructor and does not contain this regression.
The observation includes applicability; no allocation failure is claimed.

`mach_lifetime_test:parked_reply` prepares a private thread IPC state and parks
a kernel-format message holding a real task control-port send right. It calls
the common `ipc_thread_terminate` twice and reports the slot and send-right
delta before cleaning up a negative-control leak. Expected on `ee883a74` and
`db592723`: FAIL (slot retained, extra send right=1); fixed: PASS (slot NULL,
extra send rights=0). This fixture isolates cleanup used by native thread dtor
and committed exec; it does not claim a live MIG/exec round-trip or heap census.

op-437 corrects the fixture's raw `ip_active` mask to Boolean observations.
`task_control_death` and `thread_control_death` now reach their named activity
checks on both images: expected FAIL / PASS remains unchanged.
For rfork, an invalid-right allocation enters `current_space` but rejects
before descriptor lookup. The fixture probes Mach urefs without a native
`fget` prerequisite, so a missing name reports KERN_INVALID_NAME. On the stale
base binding it records fresh=0, special state, and skipped namespace values=-1,
then revokes the old private space's entries via the real fileops to avoid the
base exit loop. The parent reports the named binding FAIL, not a setup failure
or timeout. Fixed reaches all namespace/special-port checks and expects PASS.
A five-second internal wait also bounds unexpected child delays. The negative
control cleanup runs only after its observations, never on a fresh binding.

## op-444 thread-control check

The worker checks that its real thread control port is active and pins it via
fixture command 6. After pthread_join the test polls its activity for at most
15 seconds, printing active state, elapsed milliseconds and the bound. ATF's
25-second timeout permits that bound. Base ee883a74 expects FAIL (port never
disabled); fixed cf398822 expects PASS (thread_dtor disables it after reaping).

There is no supported user-space thread_info/thread_get_state call: libmach's
Makefile generates seven non-thread MIG interfaces, and sys/compat/mach/defs
contains no thread interface. An always-unsupported RPC would not distinguish
live and exited threads. Per op-444's fallback, the immediate conversion check
is removed. No result code or retries are claimed; observed activity is 1 live
and eventually 0 fixed. Validator3's source review covers the dying gate.

Fixture command 13 and its run-time linker_file_lookup_symbol are removed.
No product code changes. The self-check runs both images and repeats this case
20 times on fixed; Gatekeeper proof remains separate acceptance.

## op-447 step 4 part 1

`mach_entry_knote_test:send_pin` and `:move_pin`: base FAIL with two storage
references after membership removal; fixed PASS with three, including the
notifier pin. The fixture holds the native note sx lock and observes its
shared waiter flag before removing membership, so these are controlled
interleavings, not stress. The entry and fixture holds remain on both builds;
the live producer must supply the third hold. No numeric fd result is asserted.

`mach_short_kevent_test:large_port`, `:large_set`, `:audit_boundary`, and
`:context_boundary`: base FAIL (options stripped, message consumed or size/
canary wrong); fixed PASS (short LARGE retains message; exact retry once with
requested trailer and unchanged canaries). Existing destructive short test stays.

`mach_short_kevent_test:reply_route`: base FAIL (parked MIG reply follows
the sending thread to an unrelated port); fixed PASS (unrelated receive
times out; another thread receives two distinct MIG_BAD_ID replies on a set).

`mach_short_kevent_test:wait_large` expects FAIL on batch 3: a direct
handoff consumes the message despite LARGE. Fixed: PASS, required size and
a subsequent full receive of the same message. The admission ordering uses
a scheduling pause, so this case is stress, not a controlled interleaving.

`mach_entry_test:first_copyout` covers N6. Base: expected FAIL when two
first copyouts overlap their unlocked allocation interval. Fixed: PASS, both
copyouts return the same Mach name. The fixture creates a private kernel
port and starts two real copyouts together for 200 rounds; this is stress,
not a guaranteed allocation interleaving, and a base PASS is not a proof.
