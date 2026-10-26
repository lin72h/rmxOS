TESTSDIR= ${TESTSBASE}/usr.sbin/aslmanager
KYUAFILE= yes
SCRIPTS+= size_retention_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
size_retention_test: ${.CURDIR}/size_retention.zig
	${ZIG} build-exe ${.CURDIR}/size_retention.zig ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
.include <bsd.test.mk>
