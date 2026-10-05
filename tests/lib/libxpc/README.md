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
