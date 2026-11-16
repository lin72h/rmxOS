# rmxos-install(8): imports softwareupdate's engine as the module "engine".
.include <bsd.own.mk>
PACKAGE= utilities
SCRIPTS= rmxos-install rmxos-owner rmxos-owner-seed
SCRIPTSDIR= ${BINDIR}
SCRIPTSMODE= 0555
MAN= rmxos-install.8 rmxos-owner.8 rmxos-owner-seed.8
FILESGROUPS+= LAUNCHD
LAUNCHD= org.rmxos.owner-seed.plist
LAUNCHDDIR= /etc/launchd.d
LAUNCHDMODE= 0644
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
ZIG_TARGET?= x86_64-freebsd
LIBC_SO?= ${ZIG_SYSROOT}/lib/libc.so.7
UPDATE= ${.CURDIR}/../softwareupdate
SRCS_ZIG= rmxos-install.zig owner.zig ../softwareupdate/engine.zig ../softwareupdate/sys.zig ../softwareupdate/catalog.zig ../softwareupdate/esp.zig
all: rmxos-install rmxos-owner rmxos-owner-seed
rmxos-install: ${SRCS_ZIG:S/^/${.CURDIR}\//}
	${ZIG} build-exe -O ReleaseSafe -lc ${ZIG_SYSROOT_FLAGS} --dep engine \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mroot=${.CURDIR}/rmxos-install.zig \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mengine=${UPDATE}/engine.zig -femit-bin=${.TARGET}
rmxos-owner: ${SRCS_ZIG:S/^/${.CURDIR}\//} ${.CURDIR}/rmxos-owner.zig
	${ZIG} build-exe -O ReleaseSafe -lc ${ZIG_SYSROOT_FLAGS} --dep engine \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mroot=${.CURDIR}/rmxos-owner.zig \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mengine=${UPDATE}/engine.zig -femit-bin=${.TARGET}
owner-seed-log.o: ${.CURDIR}/owner-seed-log.c
	${CC} ${CFLAGS} -I${SRCTOP}/include -c ${.CURDIR}/owner-seed-log.c -o ${.TARGET}
rmxos-owner-seed: ${SRCS_ZIG:S/^/${.CURDIR}\//} ${.CURDIR}/rmxos-owner-seed.zig owner-seed-log.o ${LIBC_SO}
	${ZIG} build-exe owner-seed-log.o ${LIBC_SO} -O ReleaseSafe -lc ${ZIG_SYSROOT_FLAGS} --dep engine \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mroot=${.CURDIR}/rmxos-owner-seed.zig \
	    -target ${ZIG_TARGET} -mcpu=x86_64_v3 -Mengine=${UPDATE}/engine.zig -femit-bin=${.TARGET}
CLEANFILES+= rmxos-install rmxos-owner rmxos-owner-seed owner-seed-log.o
.include <bsd.prog.mk>
