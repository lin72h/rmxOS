TESTSDIR= ${TESTSBASE}/sys/mach
SCRIPTS+= mach_port_model_test
op644_extract.h op644_extractUser.c: ${.CURDIR}/op644_extract.defs
	${OP631_MIG} ${OP631_FLAGS} -header op644_extract.h -user op644_extractUser.c -server /dev/null ${.ALLSRC}
mach_port_model_test: ${.CURDIR}/mach_port_model.zig op644_extract.h op644_extractUser.c
	${ZIG} build-exe ${.CURDIR}/mach_port_model.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -I. -cflags -D__MigTypeCheck=1 -- op644_extractUser.c -femit-bin=${.TARGET}
CLEANFILES+= op644_extract.h op644_extractUser.c
SCRIPTS+= mach_vm_contract_test
mach_vm_contract_test: ${.CURDIR}/mach_vm_contract.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_vm_contract.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}
SCRIPTS+= mach_debug_sysctls_test
mach_debug_sysctls_test: ${.CURDIR}/mach_debug_sysctls.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_debug_sysctls.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
SCRIPTS+= mach_exec_workqueue_test
mach_exec_workqueue_test: ${.CURDIR}/mach_exec_workqueue.zig
	${ZIG} build-exe ${.ALLSRC} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
KYUAFILE= yes
SCRIPTS+= mach_fileops_test mach_swtch_test mach_short_kevent_test mach_dead_name_test mach_named_pset_test mach_translate_test mach_file_lifetime_test mach_passable_test mach_proc_info_test mach_filecaps_test mach_timeout_test mach_clock_test mach_timebase_test
SCRIPTSDIR= ${TESTSDIR}
SCRIPTS+= mach_identity_test
SCRIPTS+= mach_lifetime_test
SCRIPTS+= mach_entry_test
SCRIPTS+= mach_entry_lock_test
SCRIPTS+= mach_entry_knote_test
SCRIPTS+= mach_entry_dup_test
SCRIPTS+= mach_readiness_test
SCRIPTS+= mach_recovered_readiness_test
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${SYSROOT}/usr/lib/libprivateatf-c.a

.for _test in fileops swtch short_kevent dead_name named_pset translate file_lifetime passable proc_info filecaps timeout clock timebase entry entry_lock entry_knote entry_dup lifetime readiness
mach_${_test}_test: ${.CURDIR}/mach_${_test}.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_${_test}.zig -target x86_64-freebsd -lc -lpthread \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys ${ATF_C_ARCHIVE} -femit-bin=${.TARGET}
.endfor

SUBDIR+= translate_fixture

mach_identity_test: ${.CURDIR}/mach_identity.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_identity.zig -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys ${ATF_C_ARCHIVE} -femit-bin=${.TARGET}

.include <bsd.test.mk>

MACH_SO?= ${SYSROOT}/usr/lib/libmach.so.5
SCRIPTS+= mach_mig_pointers_test
SCRIPTS+= mach_trap_returns_test
SCRIPTS+= mach_ool_failure_test
SCRIPTS+= mach_error_prints_test
mach_error_prints_test: ${.CURDIR}/mach_error_prints.zig
	${ZIG} build-exe ${.CURDIR}/mach_error_prints.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
mach_ool_failure_test: ${.CURDIR}/mach_ool_failure.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_ool_failure.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
mach_trap_returns_test: ${.CURDIR}/mach_trap_returns.zig
	${ZIG} build-exe ${.ALLSRC} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
mach_mig_pointers_test: ${.CURDIR}/mach_mig_pointers.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}
mach_recovered_readiness_test: ${.CURDIR}/mach_recovered_readiness.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}

mach_entry_knote_test: ${.CURDIR}/revocation.zig
mach_identity_test: ${.CURDIR}/reply_audit.zig

SCRIPTS+= mach_child_setters_test
mach_child_setters_test: ${.CURDIR}/mach_child_setters.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}

SCRIPTS+= mach_host_vm_test
mach_host_vm_test: ${.CURDIR}/mach_host_vm.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}

SCRIPTS+= mach_send_possible_test
mach_send_possible_test: ${.CURDIR}/mach_send_possible.zig ${.CURDIR}/file_message.zig ${.CURDIR}/mig_arrays.zig
	${ZIG} build-exe ${.CURDIR}/mach_send_possible.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}
SCRIPTS+= mach_round3_test
mach_round3_test: ${.CURDIR}/mach_round3.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_round3.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}
SCRIPTS+= mach_round2_test
mach_round2_test: ${.CURDIR}/mach_round2.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_round2.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}

SCRIPTS+= mig_notifications_test
MIGCOM?= ${SYSROOT}/usr/bin/migcom
OP631_MIG= sh ${SRCTOP}/usr.bin/migcom/mig.sh -migcom ${MIGCOM}
OP631_FLAGS= -DPRIVATE -I${SRCTOP}/sys -I${SRCTOP}/sys/sys -I${SYSROOT}/usr/include -I${SRCTOP}/include/apple
op631_dispatchServer.c op631_dispatchServer.h: ${SRCTOP}/lib/libdispatch/src/protocol.defs
	${OP631_MIG} ${OP631_FLAGS} -header /dev/null -user /dev/null -server op631_dispatchServer.c -sheader op631_dispatchServer.h ${.ALLSRC}
op631_notifyServer.c op631_notifyServer.h: ${SRCTOP}/sbin/launchd/notify.defs
	${OP631_MIG} ${OP631_FLAGS} -header /dev/null -user /dev/null -server op631_notifyServer.c -sheader op631_notifyServer.h ${.ALLSRC}
mig_notifications_test: ${.CURDIR}/mig_notifications.zig ${.CURDIR}/file_message.zig op631_dispatchServer.c op631_notifyServer.c
	${ZIG} build-exe ${.CURDIR}/mig_notifications.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys \
	    -I. -cflags -D__MigTypeCheck=1 -- op631_dispatchServer.c op631_notifyServer.c -femit-bin=${.TARGET}
CLEANFILES+= op631_dispatchServer.c op631_dispatchServer.h op631_notifyServer.c op631_notifyServer.h
