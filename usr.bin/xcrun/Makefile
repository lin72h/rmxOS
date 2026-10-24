.include <bsd.own.mk>

PACKAGE= developer-tools
SCRIPTS= xcrun
SCRIPTSDIR= ${BINDIR}
SCRIPTSMODE= 0555
MAN_SUBPACKAGE= -man
MAN= xcrun.1
ZIG?= zig
ZIG_SYSROOT?= ${WORLDTMP:U${SYSROOT}}
.if !empty(ZIG_SYSROOT)
ZIG_SYSROOT_FLAGS= --sysroot ${ZIG_SYSROOT}
.endif
ZIG_TARGET?= x86_64-freebsd

all: xcrun
xcrun: ${.CURDIR}/xcrun.zig ${.CURDIR}/selection.zig ${.CURDIR}/developer_paths.zig
	${ZIG} build-exe -O ReleaseSafe -lc -target ${ZIG_TARGET} -mcpu=x86_64_v3 \
	    ${ZIG_SYSROOT_FLAGS} \
	    --dep developer_paths -Mroot=${.CURDIR}/xcrun.zig \
	    -Mdeveloper_paths=${.CURDIR}/developer_paths.zig -femit-bin=${.TARGET}

CLEANFILES+= xcrun

.for tool in swift swiftc swift-build swift-test swift-run swift-package sourcekit-lsp
LINKS+= ${BINDIR}/xcrun ${BINDIR}/${tool}
.endfor

.include <bsd.prog.mk>
