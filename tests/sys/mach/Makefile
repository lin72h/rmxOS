TESTSDIR= ${TESTSBASE}/sys/mach
KYUAFILE= yes
SCRIPTS+= mach_fileops_test mach_swtch_test mach_short_kevent_test mach_dead_name_test mach_named_pset_test mach_translate_test mach_file_lifetime_test mach_passable_test mach_proc_info_test mach_filecaps_test mach_timeout_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${SYSROOT}/usr/lib/libprivateatf-c.a

.for _test in fileops swtch short_kevent dead_name named_pset translate file_lifetime passable proc_info filecaps timeout
mach_${_test}_test: ${.CURDIR}/mach_${_test}.zig ${.CURDIR}/file_message.zig
	${ZIG} build-exe ${.CURDIR}/mach_${_test}.zig -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys ${ATF_C_ARCHIVE} -femit-bin=${.TARGET}
.endfor

SUBDIR+= translate_fixture

.include <bsd.test.mk>
