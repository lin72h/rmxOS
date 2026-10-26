TESTSDIR= ${TESTSBASE}/lib/launchd
KYUAFILE= yes
SCRIPTS+= launchd_consumer_test legacy_ipc_test reply_ownership_test receive_capacity_test
SCRIPTSDIR= ${TESTSDIR}
all: coordination.o libop484_launchd.so
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
MACH_SO?= ${SYSROOT}/usr/lib/libmach.so.5

# This target owns the PID-1 fixture. Its object directory and installation
# root are separate from the ordinary launchd and release overlay.
.PHONY: fixture fixture-install
fixture: coordination.o libop484_launchd.so
	@mkdir -p ${.OBJDIR}/fixture-launchd
	env -u MAKEOBJDIRPREFIX MAKEOBJDIR=${.OBJDIR}/fixture-launchd \
	    ${MAKE} -C ${SRCTOP}/sbin/launchd \
	    LAUNCHD_CONSUMER_FIXTURE=${.OBJDIR} all
fixture-install: fixture
	${INSTALL} -d ${DESTDIR}/sbin ${DESTDIR}${TESTSDIR}
	${INSTALL} -m 0555 ${.OBJDIR}/fixture-launchd/launchd ${DESTDIR}/sbin/launchd
	${INSTALL} -m 0555 libop484_launchd.so ${DESTDIR}${TESTSDIR}/libop484_launchd.so

coordination.o: ${.CURDIR}/coordination.c
	${CC} ${CFLAGS} -fPIC -c ${.ALLSRC} -o ${.TARGET}
libop484_launchd.so: ${.CURDIR}/fixture.zig ${.CURDIR}/protocol.zig
	${ZIG} build-lib ${.CURDIR}/fixture.zig ${MACH_SO} ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/lib/libthr.so.3 -dynamic -fsoname=libop484_launchd.so -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/sys -femit-bin=${.TARGET}
launchd_consumer_test: ${.CURDIR}/launchd_consumer.zig ${.CURDIR}/protocol.zig
	${ZIG} build-exe ${.CURDIR}/launchd_consumer.zig ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
legacy_ipc_test: ${.CURDIR}/legacy_ipc.zig ${.CURDIR}/fd_inventory.zig ${.CURDIR}/protocol.zig
	${ZIG} build-exe ${.CURDIR}/legacy_ipc.zig ${ATF_C_ARCHIVE} ${MACH_SO} ${SYSROOT}/usr/lib/liblaunch.so.5 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
.include <bsd.test.mk>

OP674_MIG= sh ${SRCTOP}/usr.bin/migcom/mig.sh -migcom ${SYSROOT}/usr/bin/migcom
op674_reply.h op674_replyUser.c: ${.CURDIR}/op674_reply.defs
	${OP674_MIG} -DPRIVATE -I${SRCTOP}/sys -I${SRCTOP}/sys/sys -I${SYSROOT}/usr/include -I${SRCTOP}/include/apple -header op674_reply.h -user op674_replyUser.c -server /dev/null ${.ALLSRC}
reply_ownership_test: ${.CURDIR}/reply_ownership.zig ${.CURDIR}/dispatch_receive_observation.zig ${.CURDIR}/fd_inventory.zig op674_reply.h op674_replyUser.c ${SRCTOP}/usr.sbin/notifyd/mach_ownership.c ${SRCTOP}/usr.sbin/notifyd/mach_ownership.h
	${ZIG} build-exe ${.CURDIR}/reply_ownership.zig ${ATF_C_ARCHIVE} ${MACH_SO} ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libxpc.so.5 ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/lib/libthr.so.3 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -I. -cflags -D__MigTypeCheck=1 -- op674_replyUser.c ${SRCTOP}/usr.sbin/notifyd/mach_ownership.c -femit-bin=${.TARGET}
CLEANFILES+= op674_reply.h op674_replyUser.c

receive_capacity_test: ${.CURDIR}/receive_capacity.zig
	${ZIG} build-exe ${.CURDIR}/receive_capacity.zig ${ATF_C_ARCHIVE} ${MACH_SO} ${SYSROOT}/usr/lib/liblaunch.so.5 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
