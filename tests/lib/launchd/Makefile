TESTSDIR= ${TESTSBASE}/lib/launchd
KYUAFILE= yes
SCRIPTS+= launchd_consumer_test
SCRIPTSDIR= ${TESTSDIR}
all: coordination.o libop484_launchd.so
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
MACH_SO?= ${SYSROOT}/usr/lib/libmach.so.5
coordination.o: ${.CURDIR}/coordination.c
	${CC} ${CFLAGS} -fPIC -c ${.ALLSRC} -o ${.TARGET}
libop484_launchd.so: ${.CURDIR}/fixture.zig ${.CURDIR}/protocol.zig
	${ZIG} build-lib ${.CURDIR}/fixture.zig ${MACH_SO} ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/lib/libthr.so.3 -dynamic -fsoname=libop484_launchd.so -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/sys -femit-bin=${.TARGET}
launchd_consumer_test: ${.CURDIR}/launchd_consumer.zig ${.CURDIR}/protocol.zig
	${ZIG} build-exe ${.CURDIR}/launchd_consumer.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
.include <bsd.test.mk>
