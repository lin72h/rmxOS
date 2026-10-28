# Asynchronous libxpc receive regressions

The Zig ATF program uses actual libxpc connections, Mach messages and dispatch
sources. Test-only C code projects private fields and bridges Blocks to Zig
callbacks. `XPC_CONSUMER_FIXTURE` builds these projections; ordinary builds omit
them. Hooks default to inactive, including when PID 1 loads the fixture library.

- `stale_readiness`: pause the real source handler, drain its queued message with
  another receiver, then resume. Observe whether receive returns within 300 ms,
  its timeout option and result. A next/rescue message bounds a blocking base and
  checks subsequent delivery exactly once.
- `failed_receive`: receive a valid wire buffer but inject `MACH_RCV_INTERRUPTED`,
  releasing the injected copied reply right. Observe the pipe result, unpack
  attempts and parsed-object deliveries; then check the next valid message.
- `local_port_gone`: pause a copied source handler, close its actual local receive
  right, then resume. The native invalid-name result remains real. Zeroing the
  failed receive buffer keeps the faulty base's speculative parse bounded.
  The existing send/dead-name uref reserves the name until owned cancellation;
  no unrelated allocation can reuse it during the controlled window.
  No EOF or automatic close notification is claimed.
- `remote_pending`: send two real requests and drain them without replies, then
  destroy the remote receive right. Observe each reply handler's identity,
  invocation count and error, plus the connection's cancellation state.
- `cancel_inflight`: hold an actual source-cancel callback, repeat cancellation
  and drop the initial connection reference. Pending calls complete once; owned
  ports stay present until the held callback returns, then release once.

Every case observes owned port release attempts, finalization and the actual
remaining fixture send/dead-name uref. The local name must be invalid after
completion. A serial-queue fence ensures callback observations are complete.
The Elixir self-check validator checks exact fact count/order, inputs, terminal
ATF status and false-green controls. Baseline expectations are source-derived
negative controls until a contained run records them.
# Object-model contract cases (op-211)

`object_model.zig` uses the public C XPC API. Build its ATF executable with
the existing `XPC_CONSUMER_FIXTURE=yes` library; `coordination.c` adds only an
atomic read-only reference-count projection. Ordinary installed libraries need
not export that observation. macOS omits reference-count checks and tests only
publicly observable behavior. `decode_lifetime.zig` is rmxOS-only and injects a
valid private nvlist message through the existing receive seam; it runs the
real pipe decoder, not a replacement. Its allocator check flushes the thread
cache, refreshes the jemalloc statistics epoch and compares live allocated
bytes after warmup, not RSS. No new wire protocol is introduced.

Both new programs are intentionally red at `f108926b`. Do not mark their ATF
cases as expected failures: later ownership fixes must make them pass.
The host runner isolates each case in its own process with allocator junking.
It suppresses Mach/dispatch process initialization using the existing host
registration shim; object functions and decode use the real library code.
These checks do not prove transport or connection behavior.

For explorer2 on macOS 27, use the same `object_model.zig`, Zig 0.16 and the
installed SDK (never copy SDK headers into the source tree):

```zsh
SDK=$(xcrun --sdk macosx --show-sdk-path)
sw_vers
xcrun --sdk macosx --show-sdk-version
zig version
zig test object_model.zig -lc --sysroot "$SDK" \
  -I"$SDK/usr/include" -L"$SDK/usr/lib" -lSystem
```

Use `--test-filter retainedChild` (or another test name) to isolate a case.
No ATF installation or rmxOS fixture/library is required in this form.
`OS_OBJECT_USE_OBJC=0` is set inside the import: C ownership, no ARC. The
three public constant backing symbols are declared by address only because
Zig cannot import an extern variable of incomplete C struct type; no private
object layout is imported. `xpc_copy` and fd functions are resolved by their
public names so a declared-only rmxOS function becomes a test failure rather
than preventing all other cases from linking.

Four names carry `ORACLE_REQUIRED`: `booleanConstants`,
`stringBufferIndependence`, `floatingEquality` and `resourceCopies`. Record the
normal assertion outcomes and the `ORACLE` floating/resource observations.
Signed-zero and NaN equality are observations, not guessed expectations. No
numeric hash value is compared across platforms; only equal-hash implication.
The staged macOS 27 header explicitly permits NULL dictionary-create values
(`xpc.h:1921-1924`), overriding op-213's contrary proposed interpretation.

`raw_drop_test` covers `XPC_PIPE_RECEIVE_MIG_ONLY`, including send rights,
native descriptor pipe-writer lifetime, OOL memory and OOL port arrays; a MIG
request/reply follows a non-MIG message on the same port set. Its heap case
uses jemalloc `stats.allocated`, like `repeatedDecodeHeap`, and the real receive
seam with valid nvlist bytes on hosts without Mach. Set `OP233_REAL_MACH=1`
in a Mach guest to additionally repeat the resource-bearing drops 1,024 times.
`XPC_SO` must name the `XPC_CONSUMER_FIXTURE` library; install that test-only
library under `/usr/tests/lib/libxpc/lib` (`XPC_TEST_RPATH`). The system library
and PID 1 do not need the fixture. `launchd_flood.zig` is the guest workload:
load/unload a job, send 10,000 XPC messages to the bootstrap port, compare PID 1
RSS via `ps`, and use `launchctl list` as a final MIG barrier.
The fixture DSO must use the distinct SONAME `libxpc_fixture.so.5`, and test
binaries must name that dependency explicitly. Reusing the system library's
SONAME can select an already-loaded system `libxpc` before RUNPATH is used.
