TESTSDIR= ${TESTSBASE}/lib/oslog
KYUAFILE= yes
SCRIPTS= oslog_codec_test
SCRIPTS+= oslog_api_test
SCRIPTSDIR= ${TESTSDIR}
FILESGROUPS+= FIXTURES
FIXTURES= libcodec_fixture.so literal_bundle.so
FIXTURESDIR= ${TESTSDIR}
FIXTURESMODE= 0555
FILESGROUPS+= CANARY
CANARY= canary_seed
CANARYDIR= ${TESTSDIR}
CANARYMODE= 0444
FILESGROUPS+= ORACLE963 ORACLE970
ORACLE963= oracle/build/op963/probe
ORACLE963DIR= ${TESTSDIR}/oracle/build/op963
ORACLE963MODE= 0555
ORACLE970= oracle/build/op970/probe oracle/build/op970/libfoo.dylib oracle/build/op970/literal.bundle
ORACLE970DIR= ${TESTSDIR}/oracle/build/op970
ORACLE970MODE= 0555
ZIG?= zig
ZIG_SYSROOT?= ${SYSROOT}
ATF_C_ARCHIVE?= ${OBJTOP}/lib/atf/libatf-c/libprivateatf-c.a
CODEC= ${SRCTOP}/lib/libc/gen
OSLOG_LIBC?= ${OBJTOP}/lib/libc/libc.so.7
OSLOG_LIBSYS?= ${SYSROOT}/lib/libsys.so.7
ORACLE= ${.CURDIR}/oracle_inputs
STORE_LIBS= ${OBJTOP}/lib/liblogstore/liblogstore.a ${SYSROOT}/usr/lib/libdispatch.so.5 ${SYSROOT}/usr/lib/liblaunch.so.5 ${SYSROOT}/usr/lib/libnotify.so.5 ${SYSROOT}/usr/lib/libBlocksRuntime.so.0 ${SYSROOT}/lib/libutil.so.10 ${SYSROOT}/lib/libthr.so.3 ${SYSROOT}/usr/lib/libmach.so.5
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
api_fixture.o: ${.CURDIR}/api_fixture.c ${SRCTOP}/include/os/log.h
	${CC} ${CFLAGS} -fblocks -I${SRCTOP}/include -I${SYSROOT}/usr/include -c ${.CURDIR}/api_fixture.c -o ${.TARGET}
oslog_api_test: ${.CURDIR}/api_guest.zig ${.CURDIR}/oracle.json api_fixture.o
	${ZIG} build-exe -O ReleaseSafe -lc -target x86_64-freebsd -mcpu=x86_64_v3 --sysroot ${ZIG_SYSROOT} -I${SRCTOP}/include -I${SRCTOP}/lib/liblogstore -I${SRCTOP}/contrib/atf ${.CURDIR}/api_guest.zig api_fixture.o ${STORE_LIBS} ${OSLOG_LIBC} ${OSLOG_LIBSYS} ${ATF_C_ARCHIVE} --build-id=sha1 -femit-bin=${.TARGET}
oracle/build/op963/probe: ${ORACLE}/op963/probe.c ${SRCTOP}/include/os/log.h
	mkdir -p oracle/build/op963
	${CC} ${CFLAGS} -Wno-error -O0 -fblocks -I${SRCTOP}/include -Wl,--build-id=sha1 ${ORACLE}/op963/probe.c ${OSLOG_LIBC} ${OSLOG_LIBSYS} -o ${.TARGET}
oracle/build/op970/libfoo.dylib: ${ORACLE}/op970/foo.c ${ORACLE}/op970/shared.h ${SRCTOP}/include/os/log.h
	mkdir -p oracle/build/op970
	${CC} ${CFLAGS} -O0 -fblocks -fPIC -shared -I${SRCTOP}/include -Wl,--build-id=sha1,-soname,libfoo.dylib ${ORACLE}/op970/foo.c ${OSLOG_LIBC} ${OSLOG_LIBSYS} -o ${.TARGET}
oracle/build/op970/literal.bundle: ${ORACLE}/op970/bundle.c
	mkdir -p oracle/build/op970
	${CC} ${CFLAGS} -Wno-error -O0 -fPIC -shared -Wl,--build-id=sha1 ${ORACLE}/op970/bundle.c -o ${.TARGET}
oracle/build/op970/probe: ${ORACLE}/op970/probe.c ${ORACLE}/op970/shared.h ${ORACLE}/op970/long-literal.h ${ORACLE}/op970/thirty-three.h oracle/build/op970/libfoo.dylib ${SRCTOP}/include/os/log.h
	${CC} ${CFLAGS} -O0 -fblocks -I${SRCTOP}/include -Wno-string-plus-int -Wl,--build-id=sha1,-rpath,'$$ORIGIN' ${ORACLE}/op970/probe.c ${.OBJDIR}/oracle/build/op970/libfoo.dylib ${OSLOG_LIBC} ${OSLOG_LIBSYS} -o ${.TARGET}
.include <bsd.test.mk>
