TESTSDIR= ${TESTSBASE}/lib/libasl
KYUAFILE= yes
NO_WERROR= yes
SCRIPTS+= asl_input_store_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
.PATH: ${SRCTOP}/usr.sbin/asl
INPUT_CFLAGS= -Wno-error -fblocks -DPRIVATE -D__APPLE__ -DLOG_LAUNCHD=192
INPUT_CFLAGS+= -I${SRCTOP}/usr.sbin/asl -I${SRCTOP}/include/apple -I${SRCTOP}/include -I${SRCTOP}/sys
INPUT_CFLAGS+= -I${SRCTOP}/lib/libasl -I${SRCTOP}/lib/liblaunch -I${SRCTOP}/lib/libdispatch -I${SRCTOP}/lib/libnotify -I${SRCTOP}/lib/libosxsupport
INPUT_CFLAGS+= -include ${SRCTOP}/usr.sbin/notifyd/rmx_build_compat.h
input_io.o: ${SRCTOP}/usr.sbin/asl/input_io.c ${SRCTOP}/usr.sbin/asl/asl_input.h
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${SRCTOP}/usr.sbin/asl/input_io.c -o ${.TARGET}
syslog_input.o: ${SRCTOP}/usr.sbin/asl/syslog_input.c
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${SRCTOP}/usr.sbin/asl/syslog_input.c -o ${.TARGET}
coordination.o: ${.CURDIR}/coordination.c ${SRCTOP}/usr.sbin/asl/asl_input.h
	${CC} ${CFLAGS} ${INPUT_CFLAGS} -c ${.CURDIR}/coordination.c -o ${.TARGET}
asl_input_store_test: ${.CURDIR}/asl_input_store.zig input_io.o syslog_input.o coordination.o
	${ZIG} build-exe ${.CURDIR}/asl_input_store.zig input_io.o syslog_input.o coordination.o ${SYSROOT}/usr/lib/libasl.so.1 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
.include <bsd.test.mk>
