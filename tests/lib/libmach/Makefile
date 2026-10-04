TESTSDIR= ${TESTSBASE}/lib/libmach
KYUAFILE= yes
SCRIPTS+= mach_destroy_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
MACH_SO?= ${SYSROOT}/usr/lib/libmach.so.5
mach_destroy_test: ${.CURDIR}/mach_destroy.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
.include <bsd.test.mk>
