TESTSDIR= ${TESTSBASE}/sys/launchd
KYUAFILE= yes
SCRIPTS+= launchd_getjob_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a

launchd_getjob_test: ${.CURDIR}/launchd_getjob.zig ${.CURDIR}/job_fixture.zig ${.CURDIR}/logging_budget.zig ${.CURDIR}/logging_budget.json
	${ZIG} build-exe ${.CURDIR}/launchd_getjob.zig -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libxpc \
	    -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys \
	    ${ATF_C_ARCHIVE} -femit-bin=${.TARGET}

SCRIPTS+= launchd_logging_test
launchd_logging_test: ${.CURDIR}/launchd_logging.zig ${.CURDIR}/stopped_records.zig ${.CURDIR}/job_fixture.zig ${.CURDIR}/logging_budget.zig ${.CURDIR}/logging_budget.json
	${ZIG} build-exe ${.CURDIR}/launchd_logging.zig ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libxpc -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys -femit-bin=${.TARGET}

SCRIPTS+= log_units_test log_queue_unit log_binding_unit liblog_binding_provider.so
LOGDIR= ${SRCTOP}/sbin/launchd
LOG_CFLAGS= -fblocks -DPRIVATE -D__APPLE__ -D__MigTypeCheck -ffunction-sections -fdata-sections
LOG_CFLAGS+= -I. -I${LOGDIR} -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys
LOG_CFLAGS+= -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libxpc -I${SRCTOP}/lib/libdispatch -I${SRCTOP}/lib/libosxsupport -I${SRCTOP}/lib/libmach
job_reply.h: ${LOGDIR}/job_reply.defs
	sh ${SRCTOP}/usr.bin/migcom/mig.sh -migcom ${SYSROOT}/usr/bin/migcom ${LOG_CFLAGS} -header job_reply.h -user /dev/null -server /dev/null ${LOGDIR}/job_reply.defs
CLEANFILES+= job_reply.h
log_queue_adapter.o: job_reply.h ${LOGDIR}/tests/log_queue_adapter.c ${LOGDIR}/log.c ${LOGDIR}/log.h
	${CC} ${LOG_CFLAGS} -c ${LOGDIR}/tests/log_queue_adapter.c -o ${.TARGET}
log_queue_unit: ${LOGDIR}/tests/log_queue.zig log_queue_adapter.o
	${ZIG} test ${LOGDIR}/tests/log_queue.zig log_queue_adapter.o --test-no-exec --gc-sections -lc -femit-bin=${.TARGET}
liblog_binding_provider.so: ${LOGDIR}/tests/log_binding_provider.zig
	${ZIG} build-lib ${.ALLSRC} -dynamic -lc -femit-bin=${.TARGET}
log_binding_unit: ${LOGDIR}/tests/log_binding.zig log_queue_adapter.o liblog_binding_provider.so
	${ZIG} test ${LOGDIR}/tests/log_binding.zig log_queue_adapter.o liblog_binding_provider.so --test-no-exec --gc-sections -lc -rpath /usr/tests/sys/launchd -femit-bin=${.TARGET}
log_units_test: ${.CURDIR}/log_units.zig ${.CURDIR}/job_fixture.zig ${.CURDIR}/logging_budget.zig ${.CURDIR}/logging_budget.json
	${ZIG} build-exe ${.CURDIR}/log_units.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

.include <bsd.test.mk>
