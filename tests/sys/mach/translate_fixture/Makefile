KMOD= rmx_translate_fixture
KMODDIR= /usr/tests/sys/mach
SRCS= adapter.c vnode_if.h
OBJS+= probe.o
SYSDIR= ${.CURDIR}/../../../../sys
CFLAGS+= -DCOMPAT_MACH -I${SYSDIR}/sys -I${SYSDIR}/../include -I${SYSDIR}/../include/apple
CFLAGS+= -Wno-error=undef
ZIG?= zig
probe.o: ${.CURDIR}/probe.zig
	${ZIG} build-obj ${.ALLSRC} -target x86_64-freestanding-none \
	    -mcmodel=kernel -mno-red-zone -fno-stack-check -fno-stack-protector \
	    -fno-compiler-rt -femit-bin=${.TARGET}
.include <bsd.kmod.mk>
