.include <bsd.own.mk>
PACKAGE= utilities
SCRIPTS= softwareupdate
SCRIPTSDIR= ${BINDIR}
SCRIPTSMODE= 0555
MAN= softwareupdate.8
FILESGROUPS+= DEFAULTS
DEFAULTS= softwareupdate.conf
DEFAULTSDIR= /etc/defaults
DEFAULTSMODE= 0644
FILESGROUPS+= LAUNCHD
LAUNCHD= org.rmxos.softwareupdate.boot-check.plist org.rmxos.softwareupdate.ownership
LAUNCHDDIR= /etc/launchd.d
LAUNCHDMODE= 0644
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
ZIG_TARGET?= x86_64-freebsd
SRCS_ZIG= softwareupdate.zig sys.zig catalog.zig engine.zig esp.zig
all: softwareupdate
softwareupdate: ${SRCS_ZIG:S/^/${.CURDIR}\//}
	${ZIG} build-exe -O ReleaseSafe -lc -target ${ZIG_TARGET} -mcpu=x86_64_v3 ${ZIG_SYSROOT_FLAGS} ${.CURDIR}/softwareupdate.zig -femit-bin=${.TARGET}
CLEANFILES+= softwareupdate
.include <bsd.prog.mk>
