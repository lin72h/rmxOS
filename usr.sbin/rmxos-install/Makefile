# rmxos-install(8): imports softwareupdate's engine as the module "engine".
.include <bsd.own.mk>
PACKAGE= utilities
SCRIPTS= rmxos-install
SCRIPTSDIR= ${BINDIR}
SCRIPTSMODE= 0555
MAN= rmxos-install.8
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
ZIG_TARGET?= x86_64-freebsd
UPDATE= ${.CURDIR}/../softwareupdate
SRCS_ZIG= rmxos-install.zig ../softwareupdate/engine.zig ../softwareupdate/sys.zig ../softwareupdate/catalog.zig ../softwareupdate/esp.zig
all: rmxos-install
rmxos-install: ${SRCS_ZIG:S/^/${.CURDIR}\//}
	${ZIG} build-exe -O ReleaseSafe -lc ${ZIG_SYSROOT_FLAGS} --dep engine \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mroot=${.CURDIR}/rmxos-install.zig \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mengine=${UPDATE}/engine.zig -femit-bin=${.TARGET}
CLEANFILES+= rmxos-install
.include <bsd.prog.mk>
