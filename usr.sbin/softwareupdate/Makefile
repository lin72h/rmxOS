.include <bsd.own.mk>
PACKAGE= utilities
SCRIPTS= softwareupdate
SCRIPTSDIR= ${BINDIR}
SCRIPTSMODE= 0555
MAN= softwareupdate.8
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
ZIG_TARGET?= x86_64-freebsd
all: softwareupdate
softwareupdate: ${.CURDIR}/softwareupdate.zig ${.CURDIR}/update.zig ${.CURDIR}/install.zig
	${ZIG} build-exe -O ReleaseSafe -lc ${ZIG_SYSROOT}/usr/lib/libarchive.so.7 -I${SRCTOP}/contrib/libarchive/libarchive -target ${ZIG_TARGET} -mcpu=x86_64_v3 ${ZIG_SYSROOT_FLAGS} ${.CURDIR}/softwareupdate.zig -femit-bin=${.TARGET}
CLEANFILES+= softwareupdate
HAS_TESTS=

SUBDIR.${MK_TESTS}+= tests
.include <bsd.prog.mk>
