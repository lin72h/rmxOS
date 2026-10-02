# Mach fix regressions

## Batch 3 (op-426)

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
