.include <bsd.init.mk>

LIB=	notify
NO_WERROR=yes
NO_WTHREAD_SAFETY=yes

.PATH: .
.PATH: ../../sbin/launchd

BASE_INCLUDE= -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR} -I. -I${.CURDIR}/../liblaunch
BASE_INCLUDE+= -I${.CURDIR}/../libdispatch -I${.CURDIR}/../libasl
BASE_INCLUDE+= -I${.CURDIR}/../libosxsupport
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys -I${.CURDIR}
DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
CFLAGS+= ${MIG_FLAGS} -D__MigTypeCheck 
CFLAGS+= -Wno-error=macro-redefined
CFLAGS+= -Wno-error=strict-prototypes
CFLAGS+= -Wno-error=deprecated-non-prototype
CFLAGS+= -Wno-error=cast-qual
CFLAGS+= -Wno-error=unused-but-set-variable
LIBADD=	BlocksRuntime dispatch launch mach osxsupport thr
.if defined(SYSROOT) && !empty(SYSROOT)
MIGCOM?= ${SYSROOT}/usr/bin/migcom
.else
MIGCOM?= ${OBJTOP}/usr.bin/migcom/migcom
.endif
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${MIGCOM}

notify_ipc.h notify_ipcUser.c: notify_ipc.defs
	${MIG} ${MIG_FLAGS} ${.CURDIR}/notify_ipc.defs

notify_client.c: notify_ipc.h notify_ipcUser.c

SRCS=	libnotify.c \
	notify_client.c \
	table.c \
	notify_ipcUser.c
INCS=	notify.h

CLEANFILES+= *User.c *Server.c notify_ipc.h

.include <bsd.lib.mk>
