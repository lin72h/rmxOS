TESTSDIR= ${TESTSBASE}/lib/libxpc
KYUAFILE= yes
SCRIPTS+= xpc_receive_test
SCRIPTS+= receive_pending_test
SCRIPTS+= raw_drop_test
SCRIPTS+= object_model_test decode_lifetime_test stage_a_test
CLEANFILES+= ${SCRIPTS}
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
XPC_SO?= ${SYSROOT}/usr/lib/libxpc.so.5
XPC_TEST_RPATH?= /usr/tests/lib/libxpc/lib
raw_drop_test: ${.CURDIR}/raw_drop.zig
	${ZIG} build-exe ${.ALLSRC} ${XPC_SO} ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/usr/lib/libnv.so ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -idirafter ${SYSROOT}/usr/include/apple -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -I${SRCTOP}/lib/libxpc -I${.CURDIR} -rpath ${XPC_TEST_RPATH} -femit-bin=${.TARGET}
object_model_test: ${.CURDIR}/object_model.zig
	${ZIG} build-exe ${.ALLSRC} ${XPC_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -idirafter ${SYSROOT}/usr/include/apple -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}
decode_lifetime_test: ${.CURDIR}/decode_lifetime.zig
	${ZIG} build-exe ${.ALLSRC} ${XPC_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -idirafter ${SYSROOT}/usr/include/apple -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -I${SRCTOP}/lib/libxpc -I${.CURDIR} -femit-bin=${.TARGET}
stage_a_test: ${.CURDIR}/stage_a.zig
	${ZIG} build-exe ${.ALLSRC} ${XPC_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc \
	    --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -idirafter ${SYSROOT}/usr/include/apple -I${SRCTOP}/contrib/atf \
	    -I${SRCTOP}/sys -femit-bin=${.TARGET}
xpc_receive_test: ${.CURDIR}/xpc_receive.zig ${.CURDIR}/reconnect.zig
	${ZIG} build-exe ${.CURDIR}/xpc_receive.zig ${XPC_SO} ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -rpath ${XPC_TEST_RPATH} -femit-bin=${.TARGET}
.include <bsd.test.mk>

receive_pending_test: ${.CURDIR}/receive_pending.zig
	${ZIG} build-exe ${.CURDIR}/receive_pending.zig ${XPC_SO} ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/libmach.so.5 ${SYSROOT}/lib/libthr.so.3 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -rpath ${XPC_TEST_RPATH} -femit-bin=${.TARGET}
