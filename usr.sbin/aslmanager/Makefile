.include <src.opts.mk>
PROG= aslmanager
NO_WERROR=yes

MAN= aslmanager.8

.PATH: .
.PATH: ${.CURDIR}
.PATH: ${.CURDIR}/support
.PATH: ${.CURDIR}/uuid
.PATH: ${.CURDIR}/init


BASE_INCLUDE=  -I. -I${.CURDIR} -I${.CURDIR}/init -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
#override default CFLAGS
CFLAGS= ${MIG_FLAGS}  -D__MigTypeCheck
CFLAGS+= -I${.CURDIR}/../../contrib/openbsm -I${.CURDIR}/../../lib/liblaunch -I${.CURDIR}/../../lib/libasl -I${.CURDIR}/../../lib/libdispatch
CFLAGS+= -I${.CURDIR}/../../lib/libxpc -I${.CURDIR}/../../lib/libosxsupport -I${.CURDIR}/../../lib/libnotify
CFLAGS+= -DHAVE_INTTYPES_H

OBJLIB= ${OBJTOP}/lib

SRCS= aslmanager.c
LDADD+= -Wl,--start-group
LDADD+= ${OBJLIB}/libasl/libasl.a
LDADD+= ${OBJLIB}/libnotify/libnotify.a
LDADD+= ${OBJLIB}/liblaunch/liblaunch.a
LDADD+= ${OBJLIB}/libxpc/libxpc.a
LDADD+= ${OBJLIB}/libdispatch/libdispatch.a
LDADD+= ${OBJLIB}/libosxsupport_rmx/libosxsupport.a
LDADD+= ${OBJLIB}/libmach/libmach.a
LDADD+= ${OBJLIB}/libthr/libthr.a
LDADD+= ${OBJLIB}/libsys/libsys.a
LDADD+= ${OBJLIB}/libc/libc.a
LDADD+= ${OBJLIB}/libbsm/libbsm.a
LDADD+= ${OBJLIB}/libauditd/libprivateauditd.a
LDADD+= ${OBJLIB}/libblocksruntime/libBlocksRuntime.a
LDADD+= ${OBJLIB}/libnv/libnv.a
LDADD+= ${OBJLIB}/libsbuf/libsbuf.a
LDADD+= ${OBJLIB}/libutil/libutil.a
LDADD+= ${OBJLIB}/libz/libz.a
LDADD+= -Wl,--end-group

.include <bsd.prog.mk>
