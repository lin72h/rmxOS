TESTSDIR= ${TESTSBASE}/sys/launchd
KYUAFILE= yes
SCRIPTS+= launchd_getjob_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${SYSROOT}/usr/lib/libprivateatf-c.a

launchd_getjob_test: ${.CURDIR}/launchd_getjob.zig
	${ZIG} build-exe ${.ALLSRC} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libxpc \
	    -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys \
	    ${ATF_C_ARCHIVE} -femit-bin=${.TARGET}

.include <bsd.test.mk>
