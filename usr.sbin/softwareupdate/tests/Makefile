TESTSDIR= ${TESTSBASE}/usr.sbin/softwareupdate
KYUAFILE= yes
SCRIPTS= softwareupdate_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
softwareupdate_test: ${.CURDIR}/softwareupdate_test.zig ${.CURDIR}/checks.zig ${.CURDIR}/catalog_checks.zig ${.CURDIR}/install_checks.zig ${.CURDIR}/lifecycle_checks.zig ${.CURDIR}/../update.zig ${.CURDIR}/../install.zig ${.CURDIR}/../lifecycle.zig ${.CURDIR}/../download.zig ${.CURDIR}/seal_checks.zig ${.CURDIR}/../seal.zig ${.CURDIR}/seal_guest.zig ${.CURDIR}/mount_checks.zig ${.CURDIR}/lineage_checks.zig
	${ZIG} build-exe -O ReleaseSafe -lc ${ZIG_SYSROOT}/usr/lib/libarchive.so.7 -I${SRCTOP}/contrib/libarchive/libarchive -target x86_64-freebsd -mcpu=x86_64_v3 --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf ${ATF_C_ARCHIVE} --dep update -Mroot=${.CURDIR}/softwareupdate_test.zig -I${SRCTOP}/contrib/libarchive/libarchive -Mupdate=${.CURDIR}/../update.zig -femit-bin=${.TARGET}
CLEANFILES+= ${SCRIPTS}
.include <bsd.test.mk>
