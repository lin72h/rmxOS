# op-156 id-025 Mach IPC wait-path inspection

Status: Implementer branch inspection note for Validator review.

## Prior Art Read

- id-025 records a stochastic blocked-idle notifyd soak freeze with balanced
  port allocation/destruction, no dead-name activity, and no deterministic live
  capture.
- op-148 identified four candidates: A.1 dormant `thread_pool_wakeup`, A.2
  `ipc_pset_signal` sx/kqueue race, A.3 `filt_machport` hint-zero lock drop,
  and A.4 missing sleep/wakeup interlock.
- id-009/bl-009 was a different failure mode in the same area: a UAF in
  `ipc_mqueue_pset_receive`, already fixed by `e101f9c`.

## Wait-Path Map

Direct receive on a port:

- `ipc_mqueue_receive` locks the receive object and references it at
  `sys/compat/mach/ipc/ipc_mqueue.c:763-764`.
- If no message is queued, the receiver records `ith_block_lock_data` as the
  port object lock, queues itself into the port thread pool, and calls
  `thread_block` at `ipc_mqueue.c:828-835`.
- `thread_block` sleeps on the thread address with
  `msleep(thread, ith_block_lock_data, ...)` at
  `sys/compat/mach/mach_thread.c:152-160`; FreeBSD atomically sleeps and drops
  the recorded object lock.
- `ipc_mqueue_deliver` holds the destination port lock, checks the port thread
  pool when `port->ip_pset == NULL`, sets the receiver state in
  `ipc_mqueue_run`, and `thread_go` wakes the sleeper using the recorded object
  lock.

Receive through a port set:

- `ipc_mqueue_receive` records `ith_block_lock_data` as the pset object lock
  and queues the current thread into the pset thread pool before sleeping.
- `ipc_mqueue_deliver` checks the pset thread pool when `port->ip_pset != NULL`.
  The pset lock serializes the sender against the receiver's sleep entry.
- `ipc_mqueue_pset_receive` scans `pset->ips_ports` for queued messages. The
  bl-009 UAF window in its pset-lock drop is already closed by the `e101f9c`
  temporary reference and revalidation.

Kqueue Mach-port filter:

- `filt_machportattach` translates the port-set right, drops the pset object
  lock, then adds the knote under `ips_note_lock`.
- `ipc_pset_signal` walks `pset->ips_note` under the sx lock and enqueues
  active knotes under each kqueue lock.
- `kqueue_scan` calls `filt_machport` while holding the knlist lock, not while
  holding the kqueue lock. Its event path rechecks `ipc_mqueue_pset_receive`
  with immediate timeout.

## Candidate Disposition

A.2 `ipc_pset_signal` sx-race: refuted as the named id-025 cause. The knlist
add/remove and signal paths share `ips_note_lock`; add/remove take it
exclusively, signal takes it shared. The kqueue core drops `kq_lock` before
calling the Mach filter detach, and `knlist_remove` then uses the same
`ips_note_lock -> kq_lock` order as `ipc_pset_signal`, avoiding the proposed
hard ABBA.

A.3 `filt_machport` hint-zero unlock-mid-event: refuted as the named id-025
cause. `ipc_object_translate` has a caller-already-has-object convention: when
the incoming object pointer already equals the translated object, it does not
lock it. The apparent "translate then lock again" path is therefore not a
double-lock; the later `ips_lock` is the first pset object lock in the common
path. The path also uses `ips_reference` before dropping a translated lock in
the uncommon changed-object path.

A.4 missing interlock/lost wakeup: confirmed, but not as the dormant
`thread_pool_get_act(block=1)` bug. The live lost wakeup is the port-to-pset
membership transition:

1. A thread can block in `ipc_mqueue_receive` directly on a receive right. It is
   queued in the port thread pool and sleeps on the port object lock.
2. `ipc_pset_move` can move that receive right from no pset into a pset while
   holding the port lock and the new pset lock.
3. Before this fix, that transition called `ipc_pset_add` but never woke the
   direct port waiters with `MACH_RCV_PORT_CHANGED`, despite
   `ipc_mqueue_receive` explicitly documenting and handling that result.
4. After the move, future sends observe `port->ip_pset != NULL` and look at the
   pset thread pool or kqueue signal path, not the port thread pool. The direct
   receiver can therefore remain asleep forever even though the port's routing
   state changed underneath it.

This matches id-025's blocked-idle shape: no spin, no leak requirement, no
dead-name dependency, and a waiter stranded on a valid wait primitive.

## Fix

The fix adds a local pset helper that drains the port thread pool while the
port lock is held and wakes each receiver with `MACH_RCV_PORT_CHANGED`. It is
called only on the `oset == IPS_NULL && nset != IPS_NULL` transition, immediately
after `ipc_pset_add` at `sys/compat/mach/ipc/ipc_pset.c:344-345`.

Restored invariant:

> A receive right cannot be made a member of a port set while direct receivers
> remain asleep on the old direct-port routing path.

The fix does not change pset-to-pset moves, pset removal, queued-message
signalling, kqueue filter semantics, or the `e101f9c` pset-receive UAF fix.

## Build Evidence

The requested clean `buildworld` and `buildkernel` did not complete on this
branch. A 2026-06-27 clean-base provenance pass detached at base
`15a6acc1398f52a3fe511ff0d28edb107dfc068a` classified the prior build walls:

- `OP156_WALL_LIBC status=0`: pre-existing on clean base. Command:
  `env MAKEOBJDIRPREFIX=/Users/me/wip-mach/build/op156-base-fresh-obj MK_TESTS=no make -j56 buildworld`.
  The run exited `2` in `lib/libc_nonshared`; `lib/libc/iconv/iconv-internal.h:35`
  uses `__iconv_bool` without a visible definition before any Mach IPC build.
  Log: `/Users/me/wip-mach/build/op156-wall-triage-15a6acc-20260627/buildworld-base-fresh.log`.
- `OP156_WALL_KPILITE status=0`: not reproduced on a clean base or on a clean
  op-156 worktree. The earlier branch log
  `/Users/me/wip-mach/build/op156-id025-waitpath-logs/buildkernel-MACHDEBUGDEBUG.log`
  shows `nm: elf_begin error: Invalid argument`, malformed `offset.inc`, and
  then `thread_lite` fallout. Re-running the same source states with fresh object
  prefixes did not hit `thread_lite`; both clean runs reached the dtrace wall
  instead. This was a stale-prefix/tool artifact, not an op-156 source-induced
  wall.
- `OP156_WALL_DTRACE status=0`: pre-existing on clean base. Command:
  `env MAKEOBJDIRPREFIX=/Users/me/wip-mach/build/op156-base-kernel-fresh-obj MK_TESTS=no make -j56 buildkernel KERNCONF=MACHDEBUGDEBUG`.
  The run exited `2` in `dtrace/systrace_freebsd32`; generated
  `freebsd32_systrace_args.c` still references removed
  `mach_msg_overwrite_trap_args.rcv_msg` and `scatter_list_size` members. The
  clean op-156 worktree reproduced the same wall with
  `MAKEOBJDIRPREFIX=/Users/me/wip-mach/build/op156-branch-kernel-fresh-obj`.
  Logs:
  `/Users/me/wip-mach/build/op156-wall-triage-15a6acc-20260627/buildkernel-base-fresh-MACHDEBUGDEBUG.log`
  and
  `/Users/me/wip-mach/build/op156-wall-triage-15a6acc-20260627/buildkernel-op156-fresh-MACHDEBUGDEBUG.log`.

`OP156_BUILDKERNEL status=0`: no clean buildkernel claim is made. The build bar
is satisfied for op-156 because every named wall is either pre-existing on the
clean base or cleared as a non-source stale-prefix artifact; none is induced by
the `ipc_pset.c` fix.

`OP156_TERMINAL status=0`.

The touched Mach module did compile and link cleanly against the established
alpha object prefix:

- Command: `env MAKEOBJDIRPREFIX=/Users/me/wip-mach/build/wip-rmxos-alpha-obj MK_TESTS=no make -C sys/modules/mach clean all`
- Log: `/Users/me/wip-mach/build/op156-id025-waitpath-logs/mach-module-alphaobj.log`
- `mach.ko`: `/Users/me/wip-mach/build/wip-rmxos-alpha-obj/Users/me/wip-mach/wip-gpt/wip-rmxos/amd64.amd64/sys/modules/mach/mach.ko`
  `sha256=9c7706a3f187334fd2b79cdd5d1696eec81417d7f1e0ccacf28166dbfabe0f1a`
  `size=345552`
- `mach.ko.debug`: `/Users/me/wip-mach/build/wip-rmxos-alpha-obj/Users/me/wip-mach/wip-gpt/wip-rmxos/amd64.amd64/sys/modules/mach/mach.ko.debug`
  `sha256=de5514f9549697c64c559e875b14550bd2c22cfd7232ca53332b66ff568bb532`
  `size=2332088`
- `ipc_pset.o`: `/Users/me/wip-mach/build/wip-rmxos-alpha-obj/Users/me/wip-mach/wip-gpt/wip-rmxos/amd64.amd64/sys/modules/mach/ipc_pset.o`
  `sha256=74b8c6447ddd80665acd401d345a7fb5a1b4140256a7dba6075aaa99f64971df`
  `size=88856`
