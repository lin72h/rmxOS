# rmxOS Base Release Profile

This versioned profile is for the rmxOS base release on amd64. It is a
configuration selection, not a build result or runtime acceptance record.

Use all three inputs together:

- `rmxos-src.conf` leaves Kerberos and Kerberos/GSSAPI at upstream defaults
  while explicitly retaining OpenSSH and OpenSSL.
- `rmxos-make.conf` excludes NFS loadable modules through `WITHOUT_MODULES`
  and sets `LOADER_NFS_SUPPORT=no` where supported. NFS userland, rc files,
  package definitions, and configuration utilities remain present.
- `../../sys/amd64/conf/RMXOS-RELEASE` inherits `MACHDEBUGDEBUG` and disables
  `NFSCL`, `NFSD`, `NFSLOCKD`, and `NFS_ROOT` without changing `GENERIC`.

For a clean candidate build, set `profile` to this directory and pass the same
pair on every operation:

```sh
profile="$SRCTOP/release/rmxos"
profile_env="__MAKE_CONF=$profile/rmxos-make.conf SRCCONF=$profile/rmxos-src.conf"
METALOG="$DESTDIR/METALOG"
make $profile_env -C "$SRCTOP" buildworld
make $profile_env -C "$SRCTOP" buildkernel KERNCONF=RMXOS-RELEASE
make $profile_env -C "$SRCTOP" installworld DESTDIR="$DESTDIR" METALOG="$METALOG"
make $profile_env -C "$SRCTOP" distribution DESTDIR="$DESTDIR" METALOG="$METALOG"
make $profile_env -C "$SRCTOP" installkernel \
    KERNCONF=RMXOS-RELEASE INSTKERNNAME=RMXOS-RELEASE \
    DESTDIR="$DESTDIR" METALOG="$METALOG"
make $profile_env -C "$SRCTOP/sys/modules" clean all
make $profile_env -C "$SRCTOP/sys/modules/mach" clean all
```

The next build must use a new empty object root, `DESTDIR`, and `METALOG`; no
existing op-335/op-336 artifact or METALOG may be reused. The profile disables
NFS kernel functionality and loadable modules, but does not claim an NFS-free
filesystem image. It retains dormant NFS userland, configuration utilities and
startup files, upstream Kerberos/GSSAPI selection, local ACL support
(`acl_nfs4`, UFS ACL, or ZFS ACL), generic RPC, OpenSSH/OpenSSL, and optional
Samba package dependencies.

The loader setting uses FreeBSD's existing `LOADER_NFS_SUPPORT` override where
the loader honors it. Loader/userland presence is intentionally not treated as
proof of an NFS-free image; image metadata and staging remain separate gates.

## Mach Test-Image Composition

`RMXOS-RELEASE` retains the kernel-side Mach hooks through `COMPAT_MACH` and
the workqueue support through `THRWORKQ`. The Darwin syscall slots remain
reserved in the kernel syscall table; `sys/compat/mach/mach_module.c` registers
their handlers when `mach.ko` initializes. The kernel options therefore do not
make the syscall-registration module redundant.

The ordinary `sys/modules` graph does not build `sys/modules/mach`. Build that
module explicitly with `make -C "$SRCTOP/sys/modules/mach" clean all`, then
stage the matching artifact as `/boot/RMXOS-RELEASE/mach.ko`. Configure its
boot-time preload in `/boot/loader.conf`:

```conf
mach_load="YES"
mach_name="/boot/RMXOS-RELEASE/mach.ko"
```

The module rejects a late load, so this is an early-boot requirement. Static
symbol and ELF checks do not establish runtime loadability; a contained guest
must confirm module initialization and syscall behavior for the exact
kernel/module pair.
