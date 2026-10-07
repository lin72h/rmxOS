TESTSDIR= ${TESTSBASE}/sys/mach
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
mach_recovered_readiness_test: ${.CURDIR}/mach_recovered_readiness.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}

mach_entry_knote_test: ${.CURDIR}/revocation.zig
mach_identity_test: ${.CURDIR}/reply_audit.zig
