.include <bsd.own.mk>

PACKAGE= developer-tools
SCRIPTS= xcode-select
SCRIPTSDIR= ${BINDIR}
SCRIPTSMODE= 0555
MAN= xcode-select.1
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
ZIG_TARGET?= x86_64-freebsd

all: xcode-select
xcode-select: ${.CURDIR}/xcode-select.zig ${.CURDIR}/selection.zig ${.CURDIR}/developer_paths.zig
	${ZIG} build-exe -O ReleaseSafe -lc -target ${ZIG_TARGET} -mcpu=x86_64_v3 \
	    ${ZIG_SYSROOT_FLAGS} \
	    --dep developer_paths -Mroot=${.CURDIR}/xcode-select.zig \
	    -Mdeveloper_paths=${.CURDIR}/developer_paths.zig -femit-bin=${.TARGET}

CLEANFILES+= xcode-select

.include <bsd.prog.mk>
