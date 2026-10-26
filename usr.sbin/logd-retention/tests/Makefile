TESTSDIR= ${TESTSBASE}/usr.sbin/logd-retention
KYUAFILE= yes
SCRIPTS+= size_retention_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
size_retention_test: ${.CURDIR}/size_retention.zig
	${ZIG} build-exe ${.CURDIR}/size_retention.zig ${OBJTOP}/lib/liblogstore/liblogstore.a ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${SYSROOT}/lib/libutil.so.10 ${SYSROOT}/lib/libthr.so.3 ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/lib/libsys.so.7 ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
.include <bsd.test.mk>
