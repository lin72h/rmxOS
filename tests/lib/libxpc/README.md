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

# Connection contracts (op-246)

`stage_a.zig` also holds the stage A connection cases. Listeners check in
with PID 1 launchd and clients look the name up through it; each case uses
its own name, `org.rmxos.op246.<case>.<pid>`, and runs as root under the
guest batch. Handlers are Blocks ABI literals built in Zig, so a handler can
retain the connection it serves the way a capturing Swift closure does.

- `tokenFields` re-executes the program as a client. The client looks the
  name up as root and then drops to the `tests` user (977:977) before it
  sends: launchd sends a non-root anonymous caller to a per-user bootstrap
  (`sbin/launchd/core.c:9293`). The kernel stamps the audit token at send.
- `retentionCheckInFails` holds `org.rmxos.logd.retention` itself, loads a
  job running logd-retention, and reads the job's `LastExitStatus` from
  `launchctl list <label>`.
- The base programs under `/usr/tests/op246-base/` bind the 8e9c9656
  fixture libxpc and the parent image's `libbsm.so.3` through their run path,
  and `retentionCheckInFails` runs the parent image's logd-retention there.

These cases need Mach and launchd; they run in the guest only.

op-257 adds `cancelNotifiesPeerChild`: the client of `cancelNotifiesPeer` runs
in a child process, cancels, keeps its reference and stays alive while the
server's peer must be told. The in-process cases stay in one process: macOS
supports both ends in one task. In the burst cases the server does not reply
to the burst request; rmxOS `xpc_dictionary_create_reply` answers any wire
message that carries an ID.

`bsm_header_test` includes only `<bsm/libbsm.h>` and calls the audit-token
field accessors: it builds only where the header declares them with
`audit_token_t` visible.

op-260 adds `noStderr` beside `noStdout`: a client and server exchange ten
messages with standard error on a pipe, and the pipe must stay empty. libxpc's
`debugf` trace exists only in builds that define `XPC_DEBUG`.
# Pack release (op-780)

`pack_release.zig` links the product `libxpc.so.5` by its soname with no run
path, so `LD_LIBRARY_PATH` selects the library under test. `heapAfterSends`
sends one dictionary (data, a nested dictionary and an array) 1,000 times on an
in-process connection and bounds the live heap (jemalloc `stats.allocated`
after an epoch refresh) at 1 MiB over the warmed start.
`descriptorsAfterRefusedSends` sends a dictionary holding an `xpc_fd_create`
value 100 times; each pack is refused, and the open descriptors other than port
names stay as they were.

# The listener's reference on a new peer (op-780)

`peer_reference.zig` links the consumer fixture, whose `op780_after_handler`
hook the listener calls after its handler returns with a new peer and before
its last read of that peer. `listenerHoldsNewPeer`: the handler gives the peer
a finalizer and cancels it; the hook waits up to 1 s for the finalizer, which
must not run before the listener's last read and must run once after it.

# Messages up to 1 MiB (op-780)

`large_message.zig` links the product `libxpc.so.5` by its soname with no run
path. libxpc's cap, `XPC_MAX_MESSAGE` (1 MiB), is the largest `msgh_size` it
sends or reads; an ordinary message has 40 bytes before its packed nvlist, a
request 56. Each case learns a dictionary's packed size from the wire, from a
listener that is never resumed.

- `sizeThreshold`: replies of 8000, 8100 and 8200 packed bytes arrive, bytes
  compared.
- `largeReply`, `largeRequest`: 64 KiB of data each way, bytes compared.
- `capBoundary`: the largest ordinary message and the largest request arrive;
  one byte more is refused at the sender (the client is interrupted), and a
  small message on the same connection arrives afterwards.
- `oversizeDropped`: a message of the cap plus 4 bytes (the smallest over the
  cap the kernel takes), built with `mach_msg`, then an ordinary one, both
  queued before the listener is resumed; the ordinary one arrives within 1 s.
- `oversizeReplyDropped`: the case answers a request on its send-once right
  with a message of the cap plus 4 bytes; the call completes once with an error
  within 1 s, and its reply port goes.

`receive_pending_test:sizes` checks the sender's `EMSGSIZE` itself, through
the fixture's `op500_pipe_send`, one byte over the cap.

# Endpoints in messages (op-796)

`endpoint_message.zig` links the product `libxpc.so.5` by its soname with no
run path. An endpoint value in a dictionary, at any depth, travels as a port
descriptor with a copy of its send right, after a request's send-once reply
right, and the packed list holds its index among the endpoint descriptors;
the receiver's endpoint object owns the right it received. In one task a send
right shares its port's name, so the in-process cases count references on the
target listener's own name (`mach_port_get_refs`); in another task a received
endpoint's name is read from its description, `(endpoint) <name>`.

- `endpointInReply` (`container`'s shape): a forked child holds an anonymous
  and a named listener and answers on the named one with an endpoint of the
  anonymous one. The parent connects from the endpoint after the reply has
  gone and makes three request-and-reply exchanges, the first held while the
  other two complete; the child reads each audit token. When the child exits,
  the connection's last event is `XPC_ERROR_CONNECTION_INVALID` and no dead
  name for the endpoint remains once the endpoint is released.
- `endpointInMessage`: an endpoint at `list[0].ep` (a dictionary in an array
  in the dictionary) in an ordinary message; the server connects from it and
  one message reaches the target. Then the wire as built: an ordinary message
  and a request read from a listener that is never resumed, and the server's
  reply to a request the case sends itself, read from a port of its own.
- `endpointReleasedBeforeUse`: the reply handler connects from the reply's
  endpoint and lets it go; one exchange follows.
- `secondEndpoint`: two endpoints of one listener from two replies, two
  clients; destroying one endpoint and cancelling its client leaves the
  listener and the other client working.
- `endpointNames`: 20 round trips, each carrying an endpoint out and back;
  the send rights on the target's name return to where they started.
- `endpointCapRefused`: 64 endpoints (the cap) arrive, 65 are refused at the
  sender (logged, the client interrupted) and a small message follows; a
  request with 64 endpoints is answered.

# The decoder's refusals and a reply's lost right (op-813, op-823)

The raw cases send their own messages to a listener's port from a reply port
R of their own (`sendRaw`, `sendRawSlot`: xpc_pipe_send_msg's layout), then a
valid message, and check that the server's descriptors and R's references
come back to where they started.

- `replyEndpointRefused`: a reply whose endpoint the kernel refuses at body
  copyin has lost its send-once right; the program's own `mach_msg_send` is
  the hook that puts a sentinel on the freed name, which the sender must not
  release again.
- `fileInEndpointSlot`: a pipe's descriptor in an endpoint's slot refuses
  the message, the file is closed once, and the next message arrives.
- `endpointIndexOutOfRange`, `endpointIndexTwice`, `endpointsOverCapReceived`:
  the decoder's other refusals, each followed by a message that arrives.
- `fileInSendOnceSlot` (op-823): a pipe's descriptor in a request's
  send-once slot (MAKE_SEND_ONCE on a file) refuses the request, the file is
  closed once, and the next request arrives.
