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
- `DISPATCH_APPLY_AUTO` and `DISPATCH_APPLY_QUEUE_ARG_NULLABILITY`

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
