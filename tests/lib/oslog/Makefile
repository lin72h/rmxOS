TESTSDIR= ${TESTSBASE}/lib/oslog
KYUAFILE= yes
SCRIPTS= oslog_codec_test
SCRIPTSDIR= ${TESTSDIR}
FILESGROUPS+= FIXTURES
FIXTURES= libcodec_fixture.so literal_bundle.so
FIXTURESDIR= ${TESTSDIR}
FIXTURESMODE= 0555
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
CODEC= ${SRCTOP}/lib/libc/gen
CLEANFILES+= codec.o compiler_fixture.o libcodec_fixture.so literal_bundle.so oslog_codec_test
codec.o: ${CODEC}/oslog_codec.c ${CODEC}/oslog_codec.h
	${CC} ${CFLAGS} -I${CODEC} -fvisibility=hidden -c ${CODEC}/oslog_codec.c -o ${.TARGET}
compiler_fixture.o: ${.CURDIR}/compiler_fixture.c ${.CURDIR}/codec_fixture.h
	${CC} ${CFLAGS} -ffreestanding -Wno-string-plus-int -I${.CURDIR} -c ${.CURDIR}/compiler_fixture.c -o ${.TARGET}
libcodec_fixture.so: ${.CURDIR}/linked_fixture.c ${.CURDIR}/codec_fixture.h
	${CC} ${CFLAGS} -ffreestanding -fPIC -shared -I${.CURDIR} -Wl,-soname,libcodec_fixture.so ${.CURDIR}/linked_fixture.c -o ${.TARGET}
literal_bundle.so: ${.CURDIR}/bundle_fixture.c
	${CC} ${CFLAGS} -fPIC -shared ${.CURDIR}/bundle_fixture.c -o ${.TARGET}
oslog_codec_test: ${.CURDIR}/oslog_codec_test.zig ${.CURDIR}/checks.zig ${.CURDIR}/fixtures.zig ${.CURDIR}/oracle.json codec.o compiler_fixture.o libcodec_fixture.so literal_bundle.so
	${ZIG} build-exe -O ReleaseSafe -lc -target x86_64-freebsd -mcpu=x86_64_v3 --sysroot ${ZIG_SYSROOT} -I${CODEC} -I${.CURDIR} -I${SRCTOP}/contrib/atf ${.CURDIR}/oslog_codec_test.zig codec.o compiler_fixture.o ${.OBJDIR}/libcodec_fixture.so ${SYSROOT}/lib/libc.so.7 ${SYSROOT}/lib/libsys.so.7 ${ATF_C_ARCHIVE} -rpath '$$ORIGIN' -femit-bin=${.TARGET}
.include <bsd.test.mk>
