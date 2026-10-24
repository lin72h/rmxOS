TESTSDIR= ${TESTSBASE}/lib/libasl
KYUAFILE= yes
NO_WERROR= yes
SCRIPTS+= asl_input_store_test asld_telemetry_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
.PATH: ${SRCTOP}/usr.sbin/asl
INPUT_CFLAGS= -Wno-error -fblocks -DPRIVATE -D__APPLE__ -DLOG_LAUNCHD=192
INPUT_CFLAGS+= -I${SRCTOP}/usr.sbin/asl -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys
INPUT_CFLAGS+= -I${SRCTOP}/lib/libasl -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libdispatch -I${SRCTOP}/lib/libnotify -I${SRCTOP}/lib/libosxsupport
INPUT_CFLAGS+= -include ${SRCTOP}/usr.sbin/notifyd/rmx_build_compat.h
input_io.o: ${SRCTOP}/usr.sbin/asl/input_io.c ${SRCTOP}/usr.sbin/asl/asl_input.h
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${SRCTOP}/usr.sbin/asl/input_io.c -o ${.TARGET}
syslog_input.o: ${SRCTOP}/usr.sbin/asl/syslog_input.c
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${SRCTOP}/usr.sbin/asl/syslog_input.c -o ${.TARGET}
coordination.o: ${.CURDIR}/coordination.c ${SRCTOP}/usr.sbin/asl/asl_input.h
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${.CURDIR}/coordination.c -o ${.TARGET}
asl_input_store_test: ${.CURDIR}/asl_input_store.zig ${.CURDIR}/store_iteration.zig input_io.o syslog_input.o coordination.o
	${ZIG} build-exe ${.CURDIR}/asl_input_store.zig input_io.o syslog_input.o coordination.o ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
asld_telemetry_test: ${.CURDIR}/asld_telemetry.zig
	${ZIG} build-exe ${.CURDIR}/asld_telemetry.zig ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

SCRIPTS+= system_logging_test
startup_error.o: ${SRCTOP}/usr.sbin/asl/startup_error.c ${SRCTOP}/usr.sbin/asl/startup_error.h
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${SRCTOP}/usr.sbin/asl/startup_error.c -o ${.TARGET}
system_logging_test: ${.CURDIR}/system_logging.zig ${.CURDIR}/logging_observations.zig ${.CURDIR}/boot_ready_check.zig startup_error.o ${.CURDIR}/log_store_scope.zig
	${ZIG} build-exe ${.CURDIR}/system_logging.zig startup_error.o ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
SCRIPTS+= op767_logger.ko
op767_logger.o: ${.CURDIR}/logger_message.zig
	${ZIG} build-obj ${.CURDIR}/logger_message.zig -target x86_64-freestanding -O ReleaseFast -mcmodel=kernel -mno-red-zone -fno-stack-check -fno-stack-protector -fno-PIC -femit-bin=${.TARGET}
op767_logger.ko: op767_logger.o
	${LD} -r -d -warn-common -o ${.TARGET} op767_logger.o

SCRIPTS+= atomic_contract_test
atomic_bridge.o: ${.CURDIR}/atomic_bridge.c ${SRCTOP}/lib/libosxsupport/atomic_compat.h
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${.CURDIR}/atomic_bridge.c -o ${.TARGET}
atomic_contract_test: ${.CURDIR}/atomic_contract.zig atomic_bridge.o
	${ZIG} build-exe ${.CURDIR}/atomic_contract.zig atomic_bridge.o ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}


SCRIPTS+= retention_observer
retention_observer: ${.CURDIR}/retention_observer.zig
	${ZIG} build-exe ${.CURDIR}/retention_observer.zig -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -femit-bin=${.TARGET}

.include <bsd.test.mk>
