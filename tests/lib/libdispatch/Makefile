TESTSDIR= ${TESTSBASE}/lib/libdispatch
KYUAFILE= yes
SCRIPTS+= dispatch_mach_test
SCRIPTS+= workqueue_lane_test
SCRIPTS+= activation_test
SCRIPTS+= time_clocks_test
SCRIPTS+= swift_exports_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${LIBATF_C}
DISPATCH_SO?= ${SYSROOT}/usr/lib/libdispatch.so.5
THR_SO?= ${SYSROOT}/lib/libthr.so.3
coordination.o: ${.CURDIR}/coordination.c
	${CC} ${CFLAGS} -fPIC -c ${.ALLSRC} -o ${.TARGET}
dispatch_mach_test: ${.CURDIR}/dispatch_mach.zig coordination.o
	${ZIG} build-exe ${.CURDIR}/dispatch_mach.zig coordination.o ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -I${SRCTOP}/lib/libdispatch -femit-bin=${.TARGET} -rdynamic

activation_test: ${.CURDIR}/activation.zig
	${ZIG} build-exe ${.CURDIR}/activation.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET} -rdynamic

workqueue_lane_test: ${.CURDIR}/workqueue_lane.zig
	${ZIG} build-exe ${.CURDIR}/workqueue_lane.zig ${THR_SO} ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}

time_clocks_test: ${.CURDIR}/time_clocks.zig
	${ZIG} build-exe ${.CURDIR}/time_clocks.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET} -rdynamic

swift_exports_test: ${.CURDIR}/swift_exports.zig
	${ZIG} build-exe ${.CURDIR}/swift_exports.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET} -rdynamic

SCRIPTS+= root_setup_test
root_setup_test: ${.CURDIR}/root_setup.zig
	${ZIG} build-exe ${.CURDIR}/root_setup.zig ${DISPATCH_SO} ${OBJTOP}/lib/liblogstore/liblogstore.a ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${SYSROOT}/lib/libutil.so.10 ${SYSROOT}/lib/libthr.so.3 ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/lib/libsys.so.7 ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET} -rdynamic

SCRIPTS+= simple_asl_unit
simple_asl.o: ${SRCTOP}/lib/libc/gen/simple_asl.c
	${CC} ${CFLAGS} -I${SRCTOP}/sys -I${SYSROOT}/usr/include -c ${.ALLSRC} -o ${.TARGET}
simple_asl_unit: ${.CURDIR}/simple_asl.zig simple_asl.o
	${ZIG} test ${.CURDIR}/simple_asl.zig simple_asl.o -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/sys --test-no-exec -femit-bin=${.TARGET}

.include <bsd.test.mk>
