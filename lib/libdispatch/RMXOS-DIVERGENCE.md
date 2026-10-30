# libdispatch: rmxOS changes that differ from upstream

rmxOS is working toward feature parity with Apple's libdispatch. Each rmxOS change
to this directory gets an entry here: what changed, how it compares with the
upstream reference, and what parity work remains. Keep entries in commit order.
Remove an entry only when a merge from upstream makes the difference go away.

## References

| Name | Version | Where read |
|---|---|---|
| Apple open source (primary reference) | libdispatch-1542.0.4, commit `2361ffb` | `apple-oss-distributions/libdispatch` |
| Swift corelibs (secondary reference) | `swift-6.4.0-RELEASE` (sha256 `af15fcc3…c104c6`), `2078b9d` | `swiftlang/swift-corelibs-libdispatch` |
| Donor of this tree | NextBSD, from Apple's libdispatch-442 era, `DISPATCH_API_VERSION 20140804` | NextBSD `lib/libdispatch` |

This tree is still the 2014 donor code; Apple 1542's API version is
`20181008`. Differences inherited from the donor are **not** listed yet. This
ledger starts with the changes below.

## D-1 Swift nullability and noescape annotations (op-238, `a2c8d03d0d96`)

Files: `dispatch/base.h`, `block.h`, `data.h`, `dispatch.h`, `group.h`,
`introspection.h`, `io.h`, `object.h`, `once.h`, `queue.h`, `semaphore.h`,
`source.h`, `time.h`.

What changed:
- `base.h` gained `DISPATCH_NOESCAPE`, `DISPATCH_ASSUME_NONNULL_BEGIN/_END`,
  and fallbacks for `__has_feature`/`__has_attribute` and
  `_Nullable`/`_Nonnull`/`_Null_unspecified`.
- `dispatch.h` includes `<string.h>`.
- Each public header has one assume-nonnull region.
- Each function rmxOS declares carries the `_Nullable` and `DISPATCH_NOESCAPE`
  annotations Apple and corelibs put on it.

Compared with Apple 1542:
- The macro definitions match Apple `base.h:228–230` and `:240–243`; the
  `<string.h>` include matches `dispatch.h:40`.
- For every function both trees declare, the count of `_Nullable`, `_Nonnull`
  and `DISPATCH_NOESCAPE` in the prototype matches. The only difference is
  spelling, in `dispatch_apply` and `dispatch_apply_f`: Apple writes the queue
  argument as `DISPATCH_APPLY_QUEUE_ARG_NULLABILITY`, which is `_Nullable` on
  current targets, and rmxOS writes `_Nullable` directly.

Not carried over from Apple:
- `DISPATCH_UNSAFE_INDEXABLE` (`-fbounds-safety`)
- `DISPATCH_ALIAS_V2`
- `API_AVAILABLE`/`API_DEPRECATED`
- `DISPATCH_SWIFT_NAME`, `DISPATCH_REFINED_FOR_SWIFT`
- `DISPATCH_APPLY_QUEUE_ARG_NULLABILITY`

Carried over later: `DISPATCH_APPLY_AUTO` (D-6, op-261).

Apple opens no region in `base.h`. rmxOS wraps `dispatch_function_t` in one.

Effect on generated code: `DISPATCH_NOESCAPE` changes the code of callers.
- Block literals passed to `dispatch_sync`, `dispatch_barrier_sync`,
  `dispatch_apply`, `dispatch_once`, `dispatch_data_apply` and
  `dispatch_block_perform` are flagged `BLOCK_IS_NOESCAPE|BLOCK_IS_GLOBAL`,
  and get no copy/dispose helpers.
- This is safe only while those functions never keep the block after they
  return. They don't today: the only copies are under
  `DISPATCH_COCOA_COMPAT && dispatch_begin_thread_4GC` and are released inside
  the call.
- Any future change to those six functions must keep that true.

## D-2 Three queue functions moved to public `queue.h` (op-238, `a2c8d03d0d96`)

`dispatch_queue_create_with_target`, `dispatch_assert_queue` and
`dispatch_assert_queue_not` moved from `private/queue_private.h` to
`dispatch/queue.h`. That is where Apple 1542 declares them (`queue.h:1068`,
`:1706`, `:1757`).

Differences from Apple:
- No `DISPATCH_UNSAFE_INDEXABLE` on `label`.
- No `DISPATCH_ALIAS_V2`.
- rmxOS kept its own documentation comments and its `_debug` macros
  (`((void)0)` under `NDEBUG`). Apple writes these as `((void)(0 && (q)))`.

## D-3 Clang module maps for `os` and `XPC` (op-238, `a2c8d03d0d96`)

Files: `include/os/module.modulemap`, `lib/libxpc/xpc/module.modulemap`. These
are outside this directory and are listed here because op-238 added them with
D-1.

Neither map exists in Apple's libdispatch or in corelibs; both are rmxOS-only.
- `XPC` uses `xpc.h` as its umbrella header and excludes `launchd.h`.
- `os` covers `base.h`, `object.h` and `log.h`. It excludes `assumes.h` and
  `trace.h`: `trace.h` includes `xpc.h`, which includes `os/object.h`, so
  covering it would make a module cycle.

This directory's own `module.modulemap` is unchanged by these ops. Its
differences from Apple's `dispatch/generic/module.modulemap` are not yet
compared.

## D-4 `DISPATCH_BAD_INPUT` at invalid-input returns (op-253, `517e64d8c5ec`)

`src/internal.h` defines `DISPATCH_BAD_INPUT ((void *_Nonnull)0)`, with the
same text as Apple `src/internal.h:552`. Apple's `DISPATCH_OUT_OF_MEMORY`
(`:553`, same expansion) is **not** defined here.

At 17 sites, `return NULL` became `return DISPATCH_BAD_INPUT`. The return value
is unchanged, and the machine code is identical to what it was before op-253.
Comparison with Apple 1542, site by site:

| rmxOS site | Function | Apple 1542 at the same check |
|---|---|---|
| `data.c:164` (malloc) | `dispatch_data_create` | `DISPATCH_OUT_OF_MEMORY` (`data.c:206`) — **name differs** |
| `data.c:354` | `dispatch_data_create_subrange` | `DISPATCH_INTERNAL_CRASH` and no return (`data.c:410`, `:440`) — **differs** |
| `io.c:324` | `dispatch_io_create` | `DISPATCH_BAD_INPUT` (`io.c:359`) |
| `io.c:375` | `dispatch_io_create_with_path` | `DISPATCH_BAD_INPUT` (`io.c:426–434`; Apple adds more checks) |
| `io.c:380` (malloc) | `dispatch_io_create_with_path` | `DISPATCH_OUT_OF_MEMORY` (`io.c:440`) — **name differs** |
| `io.c:465` | `dispatch_io_create_with_io` | `DISPATCH_BAD_INPUT` (`io.c:541`) |
| `queue.c:571` | `dispatch_get_global_queue` | `DISPATCH_BAD_INPUT` (`queue.c:8726`; Apple also rejects bad QoS at `:8730`, `:8742`) |
| `queue.c:1116` | `dispatch_queue_attr_make_with_qos_class` | returns `dqa` **unchanged** (`init.c:581`) — **behaviour differs** |
| `queue.c:1137` | `dispatch_queue_attr_make_with_autorelease_frequency` | **no rejection**; the value is stored (`init.c:614–622`) — **behaviour differs** |
| `queue.c:2010` | `dispatch_block_create` | `DISPATCH_BAD_INPUT` (`queue.c:443`) |
| `queue.c:2020`, `:2021` | `dispatch_block_create_with_qos_class` | `DISPATCH_BAD_INPUT` (`queue.c:455`, one combined check) |
| `semaphore.c:164` | `dispatch_semaphore_create` | `DISPATCH_BAD_INPUT` (`semaphore.c:38`) |
| `source.c:100`, `:106`, `:120`, `:125` | `dispatch_source_create` | `DISPATCH_BAD_INPUT` (`source.c:50`; per-type checks live in Apple's source types) |

What remains for parity (none of it was done by op-253):
- **Naming:** add `DISPATCH_OUT_OF_MEMORY` and use it at `data.c:164` and
  `io.c:380`.
- **Behaviour, pre-existing:** these differences come from the donor and rmxOS,
  not from op-253.
  - With an invalid QoS, rmxOS returns NULL, which means the serial default
    attribute. Apple returns the caller's attribute unchanged.
  - With an invalid autorelease frequency, rmxOS returns NULL. Apple accepts
    the value.
  - rmxOS's `tests/lib/libdispatch` case `autorelease_frequency` expects the
    rejection. Changing either behaviour needs its own op and test change.
- **`dispatch_data_create_subrange`:** rmxOS returns after
  `DISPATCH_CRASH`; Apple crashes and has no return.

## D-5 `libdispatch_init` runs its body once (op-261)

File: `src/queue.c`.

What changed: `libdispatch_init` starts with an atomic exchange on a static
flag, `_dispatch_init_started`, and returns at once if the flag was already
set. `_libdispatch_init`, the constructor in `src/init.c`, calls
`libdispatch_init`, so both names share the guard.

Why: swift-corelibs-foundation 6.4.0 calls `libdispatch_init()` from
`__CFInitialize` (`CFRuntime.c:1183`) on every platform except Apple's, after
the constructor has run. A second run of the body:
- creates a second `dispatch_queue_key` with the same destructor,
  `_dispatch_queue_cleanup` (`queue.c`, `_dispatch_thread_key_create`);
- stores `&_dispatch_main_q` under the new key as well.

When `dispatch_main()` calls `pthread_exit`, both keys' destructors then run
`_dispatch_queue_cleanup2`. The first takes `dq_running` from 1 to 0 and
`do_suspend_cnt` from `DISPATCH_OBJECT_SUSPEND_LOCK` (1) to 0, and wakes the
queue. The second takes both to -1 (4294967295) and skips the wakeup, so the
main queue looks suspended and its work never runs. The second run also
registers the `pthread_atfork` handlers again and re-creates the other keys.

Compared with Apple 1542 and corelibs:
- Neither has a guard. Apple's `libdispatch_init` (`queue.c:8756`) is called
  once, by libSystem's initializer.
- Corelibs (`queue.c:7356`) has a constructor and Foundation calls it again,
  as here. Its per-thread values are fields of one `__thread` struct, not one
  pthread key each, so the second run does not double the main queue's cleanup.
- The guard is rmxOS-only. It is no longer needed once this tree moves to a
  thread-storage scheme like corelibs', or once Foundation stops calling
  `libdispatch_init` on rmxOS.

Parity work left: none for this entry beyond the thread-storage scheme above.

## D-6 `DISPATCH_APPLY_AUTO` in public `queue.h` (op-261)

File: `dispatch/queue.h`.

What changed: `DISPATCH_APPLY_AUTO` is defined as
`((dispatch_queue_t _Nonnull)0)`, next to `dispatch_apply` and inside the
header's assume-nonnull region. It has the same text as corelibs 6.4.0
`queue.h:372` and Apple 1542 `queue.h:507`. The private
`DISPATCH_APPLY_CURRENT_ROOT_QUEUE` (`private/queue_private.h`) stays `NULL`.
`dispatch_apply` already treats a NULL queue as "the current root queue"
(`apply.c`).

Differences from Apple and corelibs:
- Both define it only `#if DISPATCH_APPLY_AUTO_AVAILABLE`, and Apple then
  spells the queue argument `DISPATCH_APPLY_QUEUE_ARG_NULLABILITY`. rmxOS
  defines it unconditionally and keeps `_Nullable` on the argument (D-1).
- Apple's private header (`queue_private.h:409-417`) says in its comment that
  `DISPATCH_APPLY_CURRENT_ROOT_QUEUE` is deprecated in favour of
  `DISPATCH_APPLY_AUTO`, and defines it as `((dispatch_queue_t _Nonnull)0)`. rmxOS keeps the donor's `NULL` and its
  comment.

Parity work left:
- `DISPATCH_APPLY_AUTO_AVAILABLE` and `DISPATCH_APPLY_QUEUE_ARG_NULLABILITY`.
- Apple 1542's `dispatch_apply` with `DISPATCH_APPLY_AUTO` picks the global
  queue matching the caller's QoS. rmxOS's NULL path uses the current
  thread's root queue, or the default-priority global queue; this behaviour is
  not yet compared.

## D-7 Dispatch blocks recognized by their invoke function, read at init (op-268)

Superseded by D-8 (op-277): the run-time read below was replaced by a named
invoke function in an explicit block descriptor.

Files: `src/init.c`, `src/inline_internal.h`, `src/queue.c`, `src/queue_internal.h`.

What changed:
- `_dispatch_block_special_invoke` is a `dispatch_function_t` that
  `_dispatch_block_special_invoke_init` sets.
  - It makes one block with `_dispatch_block_create(0, NULL, 0, ^{})`, reads that
    block's invoke function and releases the block.
  - `libdispatch_init` calls it once, after the op-261 guard (D-5).
- `_dispatch_block_has_private_data` compares a block's invoke function with that
  pointer again.
- Both `#ifdef notyet` blocks from NextBSD are gone. One was the comparison; the other
  was the definition by the Mach-O symbol `____dispatch_block_create_block_invoke`,
  which does not exist on ELF.
- `_dispatch_block_get_data` keeps its `DISPATCH_BLOCK_PRIVATE_DATA_MAGIC` check.

Before this, no block was ever recognized:
- `dispatch_block_wait`, `_notify`, `_cancel` and `_testcancel` crashed with "Invalid
  block object".
- `dispatch_async` and the sync functions ran dispatch blocks as plain blocks.

Compared with Apple 1542 and corelibs 6.4.0: both define a `const` pointer from the
compiler-generated function by its assembler name in the translation unit that holds
the literal: `__asm__(OS_STRINGIFY(__USER_LABEL_PREFIX__)
"___dispatch_block_create_block_invoke")` in `src/block.cpp`.
- **Our build:** `init.o` has that function as a LOCAL `___dispatch_block_create_block_invoke`,
  so the name would resolve today.
- **Why read it at run time instead:** the name is the compiler's choice, not an
  interface, and the run-time read does not depend on it.
- **Cost:** the pointer is writable and NULL until `libdispatch_init` runs, so a block
  passed in before then is treated as plain.
- **Layout:** the captured `dbpds` sits 40 bytes into the block (32-byte
  `Block_layout` + `copy_block`), as `_dispatch_block_get_data` expects; the invoke
  function adds `0x28`.

Parity work left:
- Apple keeps the private data in a C++ object (`block.cpp`) with a destructor that
  leaves the group and releases the queue, block and voucher. rmxOS keeps the C struct
  copied into the block, with no destructor.
- Vouchers are not captured (`USE_OBJC` is 0 and `VOUCHER_USE_MACH_VOUCHER` is 0).
- QoS adoption and the wait boost call rmxOS libthr entry points that return 0 without
  acting: `_pthread_set_properties_self` and `_pthread_override_qos_class_start_direct`
  (`lib/libthr/thread/thr_workq.c:1415`, `:1461`).

## D-8 Dispatch blocks own a real group, built from their own descriptor (op-277)

Files: `src/init.c`, `src/inline_internal.h`, `src/queue.c`, `src/queue_internal.h`.
This entry replaces D-7's mechanism: there is no run-time read and no
`_dispatch_block_special_invoke_init` any more.

What changed:
- **The group:** `dbpd_group` is a `dispatch_group_t` from `dispatch_group_create()`,
  entered once in `_dispatch_block_create`.
  - The old private data embedded `DISPATCH_GROUP_INITIALIZER(1)`. With `USE_POSIX_SEM`
    that group's `sem_t` was never `sem_init`ed, so `dispatch_block_wait` stopped with
    "POSIX semaphore API failure" (op-268).
  - `dispatch_block_perform`'s private data, on the stack, has no group and keeps
    `DBF_PERFORM`.
- **The block:** `_dispatch_block_create` builds it from a static `Block_descriptor`
  (`struct dispatch_block_layout_s`: block header, then private data) with
  `BLOCK_HAS_COPY_DISPOSE`.
  - The copy helper retains the group and the inner block.
  - The dispose helper leaves the group if the block never ran, then releases the
    group, any `dbpd_queue` still set, and the inner block.
- **Recognition:** the invoke function is `_dispatch_block_create_invoke`, and
  `_dispatch_block_special_invoke` is a `const` pointer to it.
- **`_dispatch_block_get_data`** finds the private data by `offsetof` (32 bytes) and
  keeps the magic check.

Why not a block literal: a C block literal has no hook that runs when the block is
freed, and the group has to be released then. Apple 1542 and corelibs use a C++ block
literal (`src/block.cpp`) whose captured `dispatch_block_private_data_s` has a copy
constructor and a destructor. The explicit descriptor is the C equivalent; it also
names the invoke function, so no compiler-generated symbol is involved.

Compared with Apple 1542's destructor (`block.cpp`):
- **Same:** leave the group if never performed; release the group, the queue and the
  block.
- **Differs:** Apple releases the queue with `_os_object_release_internal_n(…, 2)`;
  here `dispatch_async` takes one internal reference, so one `_dispatch_release`.
- **Not here:** no voucher, so there is nothing to release for one (`USE_OBJC` 0).

Ownership:
- The private data lives inside the heap block. It is kept alive by every holder of
  the block: the creator, a `dispatch_async` copy (released after the body runs and
  the group is left), and a waiter's own reference.
- A pending `dispatch_block_notify` retains the group, not the block
  (`dispatch_group_notify_f` takes `_dispatch_retain(dg)` until `_dispatch_group_wake`).
  So the notify outlives the block.
- `dispatch_block_wait` waits on the group without retaining it, so its caller must
  hold a reference to the block, as on Apple.

Parity work left: the `USE_OBJC` layout (voucher captured before the private data) is
not built on rmxOS.

## D-9 dispatch_suspend and dispatch_resume act on the queue cluster only (op-288)

File: `src/object.c`.

What changed:
- `dispatch_suspend` and `dispatch_resume` return at once unless
  `_dispatch_object_is_suspendable` holds. That is true when the object's type has
  the queue or source meta-type (`_DISPATCH_QUEUE_TYPE`, `_DISPATCH_SOURCE_TYPE`; mach
  channels are sources) and not `_DISPATCH_ATTR_TYPE`.
  - Queue attributes carry the queue meta-type too, which is why the attribute bit is
    excluded.
  - For channels, data, groups and semaphores both calls do nothing.
- Queues and sources keep the previous behaviour: the global and root-queue returns,
  "Over-resume of an object", and the inactive-source rule.
- `dispatch_activate` is unchanged.

Before: `dispatch_resume` on any unsuspended object stopped with "Over-resume", and
upstream `dispatch_io_pipe_close` calls `dispatch_resume(io)` (op-272). Even a balanced
pair on a group, semaphore or data object faulted: the resume to zero reached
`_dispatch_wakeup`, which calls `dx_probe`, and those vtables have no `do_probe`.

Compared with Apple 1542 and corelibs 6.4.0 (`object.c`, `dispatch_suspend` and
`dispatch_resume`): both return unless `dx_cluster(dou) == _DISPATCH_QUEUE_CLUSTER`.
The 442-era vtables here have no cluster field, so membership is decided by the
type constants, in one helper.

Parity work left:
- Apple routes the calls through `_dispatch_lane_suspend`/`_resume` and the
  workloop check; this tree keeps its 442 suspend-count implementation.

## D-10 macOS's CPU names in `_dispatch_hw_get_config` (op-299)

File: `src/shims/hw_config.h`.

What changed:
- On rmxOS (`__FreeBSD__`), `_dispatch_hw_get_config` reads macOS's names, as the
  `__APPLE__` branch does:
  - `hw.logicalcpu_max` for logical CPUs;
  - `hw.physicalcpu_max` for physical CPUs;
  - `hw.activecpu` for active CPUs.
- The FreeBSD-only `kern.smp.cpus` case, which answered every query with one number, is
  gone.
- Same as Apple 1542's `src/shims/hw_config.h`.
- The kernel provides the names (`sys/kern/kern_mib.c`, op-299). A libdispatch built
  this way on a kernel without them falls back to 1, so the two ship together.

Sysctl names rmxOS (rx) now has that FreeBSD (fx) does not. Each has macOS's name, type
(int32, read-only) and meaning:

| Name | rx | fx | macOS meaning |
|---|---|---|---|
| `hw.activecpu` | `mp_ncpus` (as `hw.ncpu`) | absent | CPUs currently available |
| `hw.logicalcpu` | `mp_ncpus` | absent | logical CPUs online |
| `hw.logicalcpu_max` | `mp_ncpus` (no CPU offlining) | absent | maximum logical CPUs |
| `hw.physicalcpu` | `mp_ncores` (topology; else `mp_ncpus / smp_threads_per_core`) | absent (`kern.smp.cores`) | physical cores online |
| `hw.physicalcpu_max` | same as `hw.physicalcpu` | absent | maximum physical cores |
| `kern.wq_max_threads` | `TWQ_MAX_PROC_THREADS` (512, `kern.twq.max_proc_threads`) | absent | workqueue threads per process (macOS 27: 512) |
| `kern.wq_max_constrained_threads` | `MIN(512, TWQ_NUM_BUCKETS × twq_constrained_limit())` | absent | constrained workqueue threads per process (macOS 27: 64) |

`kern.wq_max_constrained_threads` differs in shape from macOS:
- rmxOS's constrained ceiling applies per lane: `twq_constrained_limit()`,
  `max(64, ncpu × 5)`, for each of the 6 QoS buckets' constrained lanes
  (`kern.twq.max_lane_threads`).
- macOS's is one process-wide pool. The node reports the process-wide sum: 384 on up to
  12 CPUs.
- Parity work left: a single process-wide constrained pool, if Darwin code is found to
  depend on 64.
