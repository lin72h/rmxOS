.include <bsd.own.mk>
NO_WERROR= yes
TESTSDIR= ${TESTSBASE}/usr.sbin/logd
KYUAFILE= yes
SCRIPTS+= syslog_sender_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
ASL_SOURCE= ${SRCTOP}/usr.sbin/logd
ABI_CFLAGS= -I${SRCTOP}/lib/libc/include -I${SRCTOP}/sys -Wno-error
MANUAL_CFLAGS= --sysroot=${ZIG_SYSROOT} -fblocks -DPRIVATE -D__APPLE__ -D__MigTypeCheck -Wno-error
MANUAL_CFLAGS+= -ffunction-sections -fdata-sections -fvisibility=hidden
.for dir in include/apple include sys lib/liblogstore lib/liblaunch lib/libdispatch lib/libnotify lib/libxpc lib/libosxsupport usr.sbin/logd
MANUAL_CFLAGS+= -I${SRCTOP}/${dir}
.endfor
syslog_transport_sender.o: ${.CURDIR}/syslog_transport_sender.c ${SRCTOP}/lib/libc/gen/syslog.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC:[1]} -o ${.TARGET}
syslog_transport_adapter.o: ${.CURDIR}/syslog_transport_adapter.c ${SRCTOP}/lib/libc/gen/asl_private.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC:[1]} -o ${.TARGET}
syslog_manual_adapter.o: ${.CURDIR}/syslog_manual_adapter.c
	${CC} ${CFLAGS} ${MANUAL_CFLAGS} -c ${.ALLSRC} -o ${.TARGET}
asl_private.o: ${SRCTOP}/lib/libc/gen/asl_private.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC} -o ${.TARGET}
syslog_sender_test: ${.CURDIR}/logd_stop_abi.h ${.CURDIR}/logd_recovery.zig ${.CURDIR}/syslog_sender_atf.zig ${.CURDIR}/syslog_transport.zig ${.CURDIR}/syslog_timing.zig ${.CURDIR}/syslog_reports.zig ${.CURDIR}/syslog_reconcile.zig syslog_transport_sender.o syslog_transport_adapter.o syslog_manual_adapter.o asl_private.o
	${ZIG} build-exe ${.CURDIR}/syslog_sender_atf.zig -I${.CURDIR} syslog_transport_sender.o syslog_transport_adapter.o syslog_manual_adapter.o asl_private.o ${SYSROOT}/lib/libc.so.7 ${OBJTOP}/lib/liblogstore/liblogstore.a ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${SYSROOT}/lib/libutil.so.10 ${SYSROOT}/lib/libthr.so.3 ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/lib/libsys.so.7 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libsys.so.7 ${ATF_C_ARCHIVE} --gc-sections -rdynamic -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys -I${SRCTOP}/lib/liblogstore -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libxpc -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys -femit-bin=${.TARGET}

SCRIPTS+= mach_bound_unit filesystems_unit
mach_bound_unit: ${.CURDIR}/mach_send_bound.zig syslog_transport_adapter.o
	${ZIG} test ${.CURDIR}/mach_send_bound.zig syslog_transport_adapter.o --test-no-exec -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/sys -femit-bin=${.TARGET}
filesystems_adapter.o: ${.CURDIR}/filesystems_adapter.c ${ASL_SOURCE}/filesystems.h
	${CC} ${CFLAGS} -Wno-error -c ${.CURDIR}/filesystems_adapter.c -o ${.TARGET}
filesystems_unit: ${.CURDIR}/filesystems.zig filesystems_adapter.o
	${ZIG} test ${.CURDIR}/filesystems.zig filesystems_adapter.o --test-no-exec -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -femit-bin=${.TARGET}

SCRIPTS+= cleanup_status_unit
cleanup_status_unit: ${.CURDIR}/cleanup_status.zig ${.CURDIR}/logd_recovery.zig
	${ZIG} test ${.CURDIR}/cleanup_status.zig --test-no-exec -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/lib/liblogstore -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libxpc -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys -femit-bin=${.TARGET}


SCRIPTS+= syslog_transport_unit
syslog_transport_unit: ${.CURDIR}/syslog_transport.zig syslog_transport_sender.o syslog_transport_adapter.o
	${ZIG} test ${.CURDIR}/syslog_transport.zig syslog_transport_sender.o syslog_transport_adapter.o ${SYSROOT}/lib/libc.so.7 ${OBJTOP}/lib/liblogstore/liblogstore.a ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${SYSROOT}/lib/libutil.so.10 ${SYSROOT}/lib/libthr.so.3 ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/lib/libsys.so.7 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libsys.so.7 --test-no-exec --gc-sections -rdynamic -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/sys -I${SYSROOT}/usr/include -femit-bin=${.TARGET}

.include <bsd.test.mk>
