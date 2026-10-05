TESTSDIR= ${TESTSBASE}/lib/libxpc
KYUAFILE= yes
SCRIPTS+= xpc_receive_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
XPC_SO?= ${SYSROOT}/usr/lib/libxpc.so.5
xpc_receive_test: ${.CURDIR}/xpc_receive.zig
	${ZIG} build-exe ${.CURDIR}/xpc_receive.zig ${XPC_SO} ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
.include <bsd.test.mk>
