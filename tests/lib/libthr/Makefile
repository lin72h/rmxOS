TESTSDIR= ${TESTSBASE}/lib/libthr
KYUAFILE= yes
SCRIPTS+= workqueue_engine_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${LIBATF_C}
workqueue_engine_test: ${.CURDIR}/workqueue_engine.zig ${SRCTOP}/lib/libthr/thread/thr_workq_idle.h
	${ZIG} build-exe ${.CURDIR}/workqueue_engine.zig ${SYSROOT}/lib/libthr.so.3 ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/lib/libsys.so.7 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/lib/libthr/thread -femit-bin=${.TARGET}
.include <bsd.test.mk>
