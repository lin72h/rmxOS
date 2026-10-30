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

SCRIPTS+= init_once_test
SCRIPTS+= init_twice_child
apply_auto.o: ${.CURDIR}/apply_auto.c
	${CC} ${CFLAGS} -I${SYSROOT}/usr/include -fPIC -c ${.ALLSRC} -o ${.TARGET}
init_once_test: ${.CURDIR}/init_once.zig apply_auto.o
	${ZIG} build-exe ${.CURDIR}/init_once.zig apply_auto.o ${DISPATCH_SO} ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET} -rdynamic

init_twice_child: ${.CURDIR}/init_twice_child.zig
	${ZIG} build-exe ${.CURDIR}/init_twice_child.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libmach.so.5 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -femit-bin=${.TARGET}

SCRIPTS+= dispatch_block_test
SCRIPTS+= dispatch_block_child
dispatch_block_test: ${.CURDIR}/dispatch_block.zig
	${ZIG} build-exe ${.CURDIR}/dispatch_block.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

dispatch_block_child: ${.CURDIR}/dispatch_block_child.zig
	${ZIG} build-exe ${.CURDIR}/dispatch_block_child.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -femit-bin=${.TARGET}

SCRIPTS+= io_pipe_close_test
SCRIPTS+= io_pipe_close_child
io_pipe_close_test: ${.CURDIR}/io_pipe_close.zig
	${ZIG} build-exe ${.CURDIR}/io_pipe_close.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

io_pipe_close_child: ${.CURDIR}/io_pipe_close_child.zig
	${ZIG} build-exe ${.CURDIR}/io_pipe_close_child.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -femit-bin=${.TARGET}

SCRIPTS+= suspend_resume_test
SCRIPTS+= suspend_resume_child
suspend_resume_test: ${.CURDIR}/suspend_resume.zig
	${ZIG} build-exe ${.CURDIR}/suspend_resume.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

suspend_resume_child: ${.CURDIR}/suspend_resume_child.zig
	${ZIG} build-exe ${.CURDIR}/suspend_resume_child.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -femit-bin=${.TARGET}

SCRIPTS+= pool_test
SCRIPTS+= pool_child
pool_test: ${.CURDIR}/pool.zig
	${ZIG} build-exe ${.CURDIR}/pool.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

pool_child: ${.CURDIR}/pool_child.zig
	${ZIG} build-exe ${.CURDIR}/pool_child.zig ${DISPATCH_SO} ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -rdynamic -femit-bin=${.TARGET}

SCRIPTS+= twq_capture
twq_capture: ${.CURDIR}/twq_capture.zig
	${ZIG} build-exe ${.CURDIR}/twq_capture.zig -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -femit-bin=${.TARGET}

.include <bsd.test.mk>
