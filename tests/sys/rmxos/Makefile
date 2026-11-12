TESTSDIR= ${TESTSBASE}/sys/rmxos
KYUAFILE= yes
SCRIPTS+= macos_sysctl_test
SCRIPTS+= base_modes_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${LIBATF_C}
macos_sysctl_test: ${.CURDIR}/macos_sysctl.zig
	${ZIG} build-exe ${.CURDIR}/macos_sysctl.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

base_modes_test: ${.CURDIR}/base_modes.zig
	${ZIG} build-exe ${.CURDIR}/base_modes.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

.include <bsd.test.mk>
