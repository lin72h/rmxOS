.include <src.opts.mk>
PROG= aslutil
NO_WERROR= yes

.PATH: .
.PATH: ${.CURDIR}
.PATH: ${.CURDIR}/support
.PATH: ${.CURDIR}/uuid
.PATH: ${.CURDIR}/init


MAN= aslutil.1 syslog.1

BASE_INCLUDE=  -I. -I${.CURDIR} -I${.CURDIR}/init -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
#override default CFLAGS
CFLAGS= ${MIG_FLAGS}  -D__MigTypeCheck
CFLAGS+= -I${.CURDIR}/../../contrib/openbsm -I${.CURDIR}/../../lib/liblaunch -I${.CURDIR}/../../lib/libasl -I${.CURDIR}/../../lib/libdispatch
CFLAGS+= -I${.CURDIR}/../../lib/libxpc -I${.CURDIR}/../../lib/libosxsupport -I${.CURDIR}/../../lib/libnotify
CFLAGS+= -include ${.CURDIR}/../../usr.sbin/notifyd/rmx_build_compat.h
CFLAGS+= -include ${OBJTOP}/lib/libasl/asl_ipcUser.h
CFLAGS+= -DHAVE_INTTYPES_H
CFLAGS+= -Wno-error=strict-prototypes
CFLAGS+= -Wno-error=deprecated-non-prototype
CFLAGS+= -Wno-error=missing-prototypes
CFLAGS+= -Wno-error=missing-variable-declarations
CFLAGS+= -Wno-error=unused-parameter
CFLAGS+= -Wno-error=unused-variable
CFLAGS+= -Wno-error=unused-but-set-variable
CFLAGS+= -Wno-error=sign-compare
CFLAGS+= -Wno-error=cast-qual
CFLAGS+= -Wno-error=shadow
CFLAGS+= -Wno-error=format
CFLAGS+= -Wno-error=tautological-pointer-compare
CFLAGS+= -Wno-error=incompatible-pointer-types-discards-qualifiers
CFLAGS+= -Wno-error=incompatible-pointer-types
CFLAGS+= -Wno-error=uninitialized

DEBUG_FLAGS+= -g -O0

OBJLIB= ${OBJTOP}/lib

SRCS= syslog.c
LIBADD=	asl notify launch xpc dispatch osxsupport mach thr sys bsm auditd \
	BlocksRuntime nv sbuf util

.include <bsd.prog.mk>
