TESTSDIR= ${TESTSBASE}/lib/libdispatch
KYUAFILE= yes
SCRIPTS+= dispatch_mach_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
DISPATCH_SO?= ${SYSROOT}/usr/lib/libdispatch.so.5
coordination.o: ${.CURDIR}/coordination.c
	${CC} ${CFLAGS} -fPIC -c ${.ALLSRC} -o ${.TARGET}
dispatch_mach_test: ${.CURDIR}/dispatch_mach.zig coordination.o
	${ZIG} build-exe ${.CURDIR}/dispatch_mach.zig coordination.o ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -I${SRCTOP}/lib/libdispatch -femit-bin=${.TARGET} -rdynamic
.include <bsd.test.mk>
