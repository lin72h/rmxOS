# Userland Build Integration Completion Debt

This document records the build-integration state after the imported Darwin
userland was made clean-buildable from the canonical `alpha` tree.

## Verified Build

Verified on 2026-06-19 from `alpha` with a fresh object prefix:

- Source tree: `/Users/me/wip-mach/wip-gpt/wip-rmxos`
- Object prefix: `/Users/me/wip-mach/build/block-075-alpha-final-obj`
- Logs: `/Users/me/wip-mach/build/block-075-alpha-final-clean`
- Build mode: `MK_TESTS=no MAKEOBJDIRPREFIX=<object-prefix> make clean all`
  for each imported component after the support-archive prelude.

Support prelude:

| Component | Status | Notes |
| --- | ---: | --- |
| `lib/libc` | 0 | Support archive provider |
| `lib/libsys` | 0 | Support archive provider |
| `lib/libbsm` | 0 | Support archive provider |
| `lib/libauditd` | 0 | Provides `libprivateauditd.a` |
| `lib/libblocksruntime` | 0 | Blocks runtime provider |
| `lib/libnv` | 0 | XPC/launch support provider |
| `lib/libsbuf` | 0 | Support archive provider |
| `lib/libutil` | 0 | Support archive provider |
| `lib/libz` | 0 | ASL manager support provider |
| `lib/libexpat` | 0 | Provides `libbsdxml.a` |
| `lib/libthr:libthr.a` | 0 | Archive target only; shared `libthr.so` is outside this imported-userland verification target |

Imported userland and Mach substrate:

| Component | Status |
| --- | ---: |
| `usr.bin/migcom` | 0 |
| `lib/libmach` | 0 |
| `lib/libosxsupport` | 0 |
| `lib/libosxsupport_rmx` | 0 |
| `lib/libjansson` | 0 |
| `lib/libdispatch` | 0 |
| `lib/libxpc` | 0 |
| `lib/liblaunch` | 0 |
| `lib/libnotify` | 0 |
| `lib/libasl` | 0 |
| `usr.sbin/asl` | 0 |
| `usr.sbin/aslmanager` | 0 |
| `usr.bin/aslutil` | 0 |
| `bin/launchctl` | 0 |
| `usr.sbin/notifyd` | 0 |
| `sbin/launchd` | 0 |

This is a compile/link result only. It does not claim daemon runtime parity,
launchd boot integration, service lifecycle correctness, or guest behavior.

## Inventory

1. `lib/libosxsupport_rmx/pthread_qos_shim.c`

   Provides Darwin pthread QoS attribute entry points used by imported code.
   Fidelity: stub. `pthread_attr_get_qos_class_np` returns
   `QOS_CLASS_DEFAULT` and priority 0; `pthread_attr_set_qos_class_np` accepts
   input and returns success without storing functional QoS policy.

2. `lib/libosxsupport_rmx/libinfo_cache_shim.c`

   Provides `gL1CacheEnabled` and `si_search_module_set_flags` while the
   libinfo search/cache modules remain gated out of the compatibility archive.
   Fidelity: stub for module flagging; `gL1CacheEnabled` is a real exported
   variable initialized to enabled.

3. `lib/libosxsupport_rmx/uuid_compare_shim.c`

   Provides the Darwin-shaped `uuid_compare(uuid_t, uuid_t)` symbol expected by
   launchd code. Fidelity: real compare semantics implemented with `memcmp`.

4. `lib/libosxsupport_rmx` build gate

   Consumers link the `_rmx` compatibility archive, not the full donor
   `lib/libosxsupport` archive. `_rmx` gates out donor search/cache/plugin
   modules: `si_module.c`, `search_module.c`, `si_data.c`, `cache_module.c`,
   and `file_module.c`. The donor tree also carries `mdns_module.c` and
   `si_getaddrinfo.c` as unbuilt source. Full `lib/libosxsupport` itself now
   clean-builds byte-identical source with additional include wiring.

5. `usr.sbin/notifyd/rmx_build_compat.h`

   Build-only declarations for legacy Mach VM aliases:
   `vm_allocate` and `vm_deallocate`. Fidelity: not a runtime shim; it exposes
   declarations for symbols supplied by `libmach`.

6. `sbin/launchd/rmx_build_compat.h`

   Build-only compatibility declarations and constants for launchd/libxpc.
   Fidelity: compile surface only unless backed by linked libraries.

7. MIG compiler binding

   `libmach`, `libdispatch`, `liblaunch`, `libnotify`, `libasl`, and
   `usr.sbin/asl` use the tree-built `usr.bin/migcom/mig.sh` wrapper through
   `${OBJTOP}/usr.bin/migcom/migcom`. This removes host `mig` dependence, but
   still means MIG users must be built after `migcom` in a clean prefix.

8. Generated ASL client/server header split

   `lib/libasl` generates and force-includes `asl_ipcUser.h` for client-side
   declarations. `usr.bin/aslutil` force-includes the generated
   `${OBJTOP}/lib/libasl/asl_ipcUser.h` because donor source includes
   `asl_ipc.h`, which is the server header in this tree. Fidelity: build
   routing only.

9. Static archive-group links

   `usr.sbin/asl`, `usr.sbin/aslmanager`, `usr.bin/aslutil`, `bin/launchctl`,
   `usr.sbin/notifyd`, and `sbin/launchd` link explicit object-tree archives
   with `--start-group`. `MK_PIE=no` is required for these static archive
   links. This is buildable but not yet normal installed-world library wiring.

10. Warning gates

   Imported code still carries donor warning surfaces incompatible with
   FreeBSD's default `-Werror` policy. Current `-Wno-error=*` gates are scoped
   in Makefiles for `migcom`, `libmach`, `libdispatch`, `libxpc`, `libnotify`,
   `libasl`, the ASL tools, `notifyd`, and `launchd`. Fidelity: compile policy
   only; these gates do not validate runtime behavior.

11. `libdispatch` feature gates

   The current build disables Objective-C objects, DTrace, simple ASL,
   nanozone, and legacy workqueue fallback through build defines. It enables
   the rmx pthread workqueue path with `NXPLATFORM_DISPATCH_TWQ_WORKQUEUE=1`.
   Voucher/ATM behavior is not runtime-validated by this build result.

12. `libxpc` local build surface

   `libxpc` includes local `nv.h`/`nv_impl.h` and declares `nvlist_type` for the
   imported implementation. Several XPC surfaces are compile-gated by warning
   policy, including incomplete return paths, endpoint casts, and type
   mismatches. Fidelity: buildable library, not validated XPC service parity.

13. `libnotify` build gates

   `libnotify` carries warning gates for the Darwin/FreeBSD header interface,
   including the `FD_NONE` macro conflict and legacy prototypes. Fidelity:
   buildable library, not a standalone notify correctness claim.

14. ASL compatibility gates

   `libasl` defines `LOG_LAUNCHD=192` locally to preserve the donor facility
   value without changing the system syslog policy. ASL daemon/tools inherit
   the Mach VM declaration compatibility header and warning gates. Fidelity:
   buildable ASL stack, not validated logging service behavior.

15. `notifyd` build surface

   `notifyd` links imported static archives plus `_rmx` support and includes
   `rmx_build_compat.h`. The build keeps existing warning gates for donor
   prototypes and macro conflicts. Fidelity: buildable daemon, not a booted
   service validation.

16. `launchd` build surface

   `launchd` uses the static archive-group link path, `rmx_build_compat.h`, and
   build-time compatibility definitions for Darwin kernel-event socket constants
   and NOTE values. Fidelity: buildable daemon, not PID 1 or lifecycle parity.

17. `share/mk/bsd.libnames.mk`

   Adds `LIBASL` so imported build graph references can resolve consistently.
   Fidelity: build graph entry only.

18. Support-library prelude

   The clean-prefix verification requires support archives in the same object
   tree before imported programs link. The support prelude builds those archives
   with `MK_TESTS=no`; `libthr` is verified via the `libthr.a` archive target.
   This does not claim a full world build or shared-library closure.

## Open Follow-Up

- Replace advisory QoS and libinfo/cache stubs with full-fidelity
  implementations or explicitly retain them as policy.
- Move the static archive-group program links toward normal installed-world
  library dependencies.
- Decide whether warning gates remain acceptable for imported donor code or
  should be burned down per component.
- Runtime-validate the imported daemons and tools in a guest after build
  closure: boot wiring, daemon startup, launchd handoff, notifyd service use,
  ASL logging, and XPC behavior.
