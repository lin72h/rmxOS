TESTSDIR= ${TESTSBASE}/lib/libmach
KYUAFILE= yes
SCRIPTS+= mach_destroy_test
SCRIPTS+= thread_port_test
SCRIPTS+= ool_kernel_memory_test ool_errors_test port_set_status_shortage_test
SCRIPTS+= space_info_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= /Users/me/wip-mach/rmx-implementer/build/op395/obj/Users/me/wip-mach/rmx-implementer/build/op395/source/amd64.amd64/lib/atf/libatf-c/libprivateatf-c.a
MACH_SO?= ${SYSROOT}/usr/lib/libmach.so.5
mach_destroy_test: ${.CURDIR}/mach_destroy.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
thread_port_test: ${.CURDIR}/thread_port.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${SYSROOT}/usr/lib/libdispatch.so.5 ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
ool_kernel_memory_test: ${.CURDIR}/ool_kernel_memory.zig ${.CURDIR}/ool_limits.zig
	${ZIG} build-exe ${.CURDIR}/ool_kernel_memory.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
ool_errors_test: ${.CURDIR}/ool_errors.zig ${.CURDIR}/ool_limits.zig
	${ZIG} build-exe ${.CURDIR}/ool_errors.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
port_set_status_shortage_test: ${.CURDIR}/port_set_status_shortage.zig ${.CURDIR}/ool_limits.zig
	${ZIG} build-exe ${.CURDIR}/port_set_status_shortage.zig ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc -lpthread --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
space_info_test: ${.CURDIR}/space_info.zig
	${ZIG} build-exe ${.ALLSRC} ${MACH_SO} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SYSROOT}/usr/include -I${SRCTOP}/contrib/atf -I${SRCTOP}/sys -femit-bin=${.TARGET}
.include <bsd.test.mk>
