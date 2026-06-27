.include <bsd.init.mk>

LIB=	launch

.PATH: .
.PATH: ../../sbin/launchd

BASE_INCLUDE= -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR} -I${.CURDIR}/../libxpc -I${.CURDIR}/../libdispatch
BASE_INCLUDE+= -I${.CURDIR}/../libasl
BASE_INCLUDE+= -I${.CURDIR}/../../sbin/launchd -I${.CURDIR}
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
BASE_INCLUDE+= -I${.OBJDIR}

DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
CFLAGS+= ${MIG_FLAGS} -D__MigTypeCheck -g -O0
CFLAGS+= -I${.CURDIR}/../../contrib/openbsm
LIBADD=	dispatch mach osxsupport thr sys
.if defined(SYSROOT) && !empty(SYSROOT)
MIGCOM?= ${SYSROOT}/usr/bin/migcom
.else
MIGCOM?= ${OBJTOP}/usr.bin/migcom/migcom
.endif
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${MIGCOM}

helper.h launchd_helperUser.c launchd_helperServer.c helperServer.h: helper.defs
	${MIG} ${MIG_FLAGS} -header helper.h -sheader helperServer.h ${.CURDIR}/helper.defs

job.h jobUser.c jobServer.h: job.defs
	${MIG} ${MIG_FLAGS} -sheader jobServer.h ${.CURDIR}/job.defs

SRCS= 	jobUser.c \
	launchd_helperUser.c \
	launchd_helperServer.c \
	libbootstrap.c \
	liblaunch.c \
	libvproc.c
INCS=	launch.h

CLEANFILES+= *User.c *Server.c job.h helper.h *Server.h launchd_helper.h *~

.include <bsd.lib.mk>
