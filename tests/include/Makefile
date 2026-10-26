.include <bsd.own.mk>

TESTSDIR=	${TESTSBASE}/include
KYUAFILE= yes

ATF_TESTS_C+=		byteswap_test
ATF_TESTS_C+=		byteswap_endian_test
ATF_TESTS_C+=		endian_test
ATF_TESTS_C+=		endian_sys_endian_test
ATF_TESTS_C+=		stdckdint_test
ATF_TESTS_C+=		sys_endian_test
ATF_TESTS_C+=		sys_endian_endian_test

# The executable runs the base C/C++ compilers against the installed headers.
SCRIPTS+= darwin_headers_test
SCRIPTSDIR= ${TESTSDIR}
ZIG?= zig
darwin_headers_test: ${.CURDIR}/darwin_headers.zig
	${ZIG} build-exe ${.ALLSRC} -lc -femit-bin=${.TARGET}


SCRIPTS+= developer_tools_test
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
developer_tools_test: ${.CURDIR}/developer_tools.zig
	${ZIG} build-exe ${.ALLSRC} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}

SCRIPTS+= swift_base_test swift_lookup
FILES+= libop170_swift.so.1
FILESDIR= ${TESTSDIR}
swift_base_test: ${.CURDIR}/swift_base.zig
	${ZIG} build-exe ${.ALLSRC} ${ATF_C_ARCHIVE} -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/contrib/atf -femit-bin=${.TARGET}
libop170_swift.so.1: ${.CURDIR}/swift_runtime.zig
	${ZIG} build-lib ${.ALLSRC} -dynamic -fsoname=libop170_swift.so.1 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -femit-bin=${.TARGET}
swift_lookup: ${.CURDIR}/swift_lookup.zig libop170_swift.so.1
	${ZIG} build-exe ${.CURDIR}/swift_lookup.zig libop170_swift.so.1 -target x86_64-freebsd -lc --sysroot ${ZIG_SYSROOT} -femit-bin=${.TARGET}

.include <bsd.test.mk>
