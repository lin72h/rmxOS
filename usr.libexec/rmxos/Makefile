# The first stage has no libc startup; it uses the FreeBSD/amd64 syscall ABI.
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
SCRIPTS= first-stage rmxos-datasync
SCRIPTSDIR_first-stage= /sbin
SCRIPTSNAME_first-stage= launchd
SCRIPTSDIR_rmxos-datasync= /usr/libexec
SCRIPTSMODE= 0555
MAN=
all: first-stage rmxos-datasync
first-stage: ${.CURDIR}/first-stage.zig
	${ZIG} build-exe -O ReleaseSmall -target x86_64-freestanding -mcpu=x86_64_v3 -fno-stack-check -fno-stack-protector -fno-entry -fentry=_start ${.CURDIR}/first-stage.zig -femit-bin=${.TARGET}
	brandelf -t FreeBSD ${.TARGET}
rmxos-datasync: ${.CURDIR}/datasync.zig
	${ZIG} build-exe -O ReleaseSafe -target x86_64-freebsd -mcpu=x86_64_v3 -lc ${ZIG_SYSROOT_FLAGS} ${.CURDIR}/datasync.zig -femit-bin=${.TARGET}
FILESGROUPS+= PATTERNS
PATTERNS= Data.local-patterns
PATTERNSDIR= /System/Library/Templates
PATTERNSMODE= 0444
FILESGROUPS+= VENDOR
VENDOR= ${.CURDIR}/../../etc/defaults/vendor.conf
VENDORDIR= /etc/defaults
VENDORMODE= 0644
CLEANFILES+= first-stage rmxos-datasync
.include <bsd.prog.mk>
