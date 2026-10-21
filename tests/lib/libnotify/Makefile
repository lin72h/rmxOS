TESTSDIR= ${TESTSBASE}/lib/libnotify
KYUAFILE= yes
SCRIPTS+= notify_names_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
notify_names_test: ${.CURDIR}/notify_names.zig
	${ZIG} build-exe ${.ALLSRC} ${SYSROOT}/usr/lib/libnotify.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
.include <bsd.test.mk>

SCRIPTS+= notify_startup_test
notify_startup_test: ${.CURDIR}/notify_startup.zig
	${ZIG} build-exe ${.ALLSRC} ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -rdynamic --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
