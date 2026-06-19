# $FreeBSD$

LIB=	asl
SHLIB_MAJOR=	1
SHLIBDIR?= /usr/lib
NO_WERROR=yes

DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
# NextBSD's syslog.h defines LOG_LAUNCHD as 24<<3; keep this compatibility
# local to the ASL bringup until the syslog facility policy is decided.
DEFINES+= -DLOG_LAUNCHD=192
BASE_INCLUDE= -I${.CURDIR}/../../include/apple -I${.CURDIR}/../liblaunch/ -I${.CURDIR}/../libosxsupport/ -I${.CURDIR}/../libdispatch/
BASE_INCLUDE+= -I${.CURDIR}/../libnotify/
BASE_INCLUDE+= -I${.CURDIR}/../libxpc/
BASE_INCLUDE+= -I${.CURDIR} -I${.CURDIR}/../../include -I${MACHINE_INCLUDES} -I${.CURDIR}/../../sys
MIG_FLAGS= ${BASE_INCLUDE} ${DEFINES}
CFLAGS+= ${BASE_INCLUDE} ${DEFINES} -fPIC -DPRIVATE -D__MigTypeCheck=1 -DLIBSYSCALL_INTERFACE=1
CFLAGS+= -Wno-int-conversion

SRCS=	asl.c asl_ipcUser.c asl_core.c asl_file.c asl_msg.c asl_object.c \
	asl_string.c syslog.c asl_client.c asl_fd.c asl_legacy1.c \
	asl_msg_list.c asl_store.c asl_util.c asl_common.c asl_memory.c

MAN=	asl.3 syslog.3

asl_ipc.h asl_ipcUser.c: asl_ipc.defs 
	mig ${MIG_FLAGS} -sheader asl_ipc.h ${.CURDIR}/asl_ipc.defs

asl.c: asl_ipc.h

INCS=	asl.h

.include <bsd.lib.mk>
