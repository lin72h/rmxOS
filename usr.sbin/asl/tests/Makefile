.include <bsd.own.mk>
TESTSDIR= ${TESTSBASE}/usr.sbin/asl
KYUAFILE= yes
SCRIPTS+= syslog_sender_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
ASL_SOURCE= ${SRCTOP}/usr.sbin/asl
ABI_CFLAGS= -I${SRCTOP}/lib/libc/include -I${SRCTOP}/sys
MANUAL_CFLAGS= --sysroot=${ZIG_SYSROOT} -fblocks -DPRIVATE -D__APPLE__ -D__MigTypeCheck
MANUAL_CFLAGS+= -ffunction-sections -fdata-sections -fvisibility=hidden
.for dir in include/apple include sys lib/libasl lib/liblaunch lib/libdispatch lib/libnotify lib/libxpc lib/libosxsupport usr.sbin/asl
MANUAL_CFLAGS+= -I${SRCTOP}/${dir}
.endfor
syslog_sender_adapter.o: ${.CURDIR}/syslog_sender_adapter.c ${SRCTOP}/lib/libc/gen/syslog.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC:[1]} -o ${.TARGET}
syslog_transport_sender.o: ${.CURDIR}/syslog_transport_sender.c ${SRCTOP}/lib/libc/gen/syslog.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC:[1]} -o ${.TARGET}
syslog_transport_adapter.o: ${.CURDIR}/syslog_transport_adapter.c ${SRCTOP}/lib/libc/gen/asl_private.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC:[1]} -o ${.TARGET}
syslog_manual_adapter.o: ${.CURDIR}/syslog_manual_adapter.c
	${CC} ${CFLAGS} ${MANUAL_CFLAGS} -c ${.ALLSRC} -o ${.TARGET}
asl_private.o: ${SRCTOP}/lib/libc/gen/asl_private.c
	${CC} ${CFLAGS} ${ABI_CFLAGS} -c ${.ALLSRC} -o ${.TARGET}
syslog_sender_test: ${.CURDIR}/syslog_sender_atf.zig ${.CURDIR}/syslog_transport.zig ${.CURDIR}/syslog_timing.zig ${.CURDIR}/syslog_sender.zig ${.CURDIR}/syslog_reports.zig syslog_sender_adapter.o syslog_transport_sender.o syslog_transport_adapter.o syslog_manual_adapter.o asl_private.o
	${ZIG} build-exe ${.CURDIR}/syslog_sender_atf.zig syslog_sender_adapter.o syslog_transport_sender.o syslog_transport_adapter.o syslog_manual_adapter.o asl_private.o ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libsys.so.7 ${ATF_C_ARCHIVE} --gc-sections -rdynamic -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys -I${SRCTOP}/lib/libasl -femit-bin=${.TARGET}
.include <bsd.test.mk>
