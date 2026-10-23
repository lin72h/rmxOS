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

.include <bsd.test.mk>
