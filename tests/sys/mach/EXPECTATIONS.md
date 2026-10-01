# Mach fix regressions

These are expected results, not guest observations. The Gatekeeper runs the
same test artifacts on unchanged alpha2 and the fixed image. No expected-failure
annotations hide alpha2 failures.

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

The Zig program links ATF's C ABI; registration and metadata-only `-l` do not
execute its syscall observations. Every case allocates its own receive right.
The poll error is POLLNVAL; the fcntl errors are ENOTTY; chmod, chown and native
read/write filter registration return EINVAL. The kevent cases require an
EV_ERROR receipt, not merely any event.

Fix 6 uses a freestanding Zig test module in the disposable guest. Its C adapter
only projects kernel ABI fields and routes module/sysctl calls; all observation
logic is Zig. The output pointer starts equal to the valid object pointer, so
alpha2 deterministically reports owned=0 instead of depending on stack reuse.
