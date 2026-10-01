TESTSDIR= ${TESTSBASE}/sys/mach
KYUAFILE= yes
SCRIPTS+= mach_fileops_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${SYSROOT}/usr/lib/libprivateatf-c.a

mach_fileops_test: ${.CURDIR}/mach_fileops.zig
	${ZIG} build-exe ${.ALLSRC:M*.zig} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys ${ATF_C_ARCHIVE} -femit-bin=${.TARGET}

.include <bsd.test.mk>
