# $FreeBSD$

LIB=	asl
SHLIB_MAJOR=	1
SHLIBDIR?= /usr/lib
NO_WERROR=yes

DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
# NextBSD's syslog.h defines LOG_LAUNCHD as 24<<3; keep this compatibility
# local to the ASL bringup until the syslog facility policy is decided.
DEFINES+= -DLOG_LAUNCHD=192
BASE_INCLUDE= -I. -I${.CURDIR}/../../include/apple -I${.CURDIR}/../liblaunch/ -I${.CURDIR}/../libosxsupport/ -I${.CURDIR}/../libdispatch/
BASE_INCLUDE+= -I${.CURDIR}/../libnotify/
BASE_INCLUDE+= -I${.CURDIR}/../libxpc/
BASE_INCLUDE+= -I${.CURDIR} -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
MIG_FLAGS= ${BASE_INCLUDE} ${DEFINES}
CFLAGS+= ${BASE_INCLUDE} ${DEFINES} -fPIC -DPRIVATE -D__MigTypeCheck=1 -DLIBSYSCALL_INTERFACE=1
CFLAGS+= -include ${.CURDIR}/../../usr.sbin/notifyd/rmx_build_compat.h
CFLAGS+= -include asl_ipcUser.h
CFLAGS+= -Wno-int-conversion
CFLAGS+= -Wno-error=strict-prototypes
CFLAGS+= -Wno-error=deprecated-non-prototype
CFLAGS+= -Wno-error=missing-variable-declarations
CFLAGS+= -Wno-error=missing-prototypes
CFLAGS+= -Wno-error=thread-safety-analysis
CFLAGS+= -Wno-error=cast-qual
CFLAGS+= -Wno-error=tautological-pointer-compare
CFLAGS+= -Wno-error=free-nonheap-object
CFLAGS+= -Wno-error=unused-variable
CFLAGS+= -Wno-error=unused-parameter
CFLAGS+= -Wno-error=shadow
CFLAGS+= -Wno-error=uninitialized
CFLAGS+= -Wno-error=sign-compare
CFLAGS+= -Wno-error=format
CFLAGS+= -Wno-error=unused-but-set-variable
CFLAGS+= -Wno-error=pointer-compare
CFLAGS+= -Wno-error=constant-conversion
CFLAGS+= -Wno-error=incompatible-pointer-types-discards-qualifiers
.if defined(SYSROOT) && !empty(SYSROOT)
MIGCOM?= ${SYSROOT}/usr/bin/migcom
.else
MIGCOM?= ${OBJTOP}/usr.bin/migcom/migcom
.endif
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${MIGCOM}

SRCS=	asl.c asl_ipcUser.c asl_core.c asl_file.c asl_msg.c asl_object.c \
	asl_string.c syslog.c asl_client.c asl_fd.c asl_legacy1.c \
	asl_msg_list.c asl_store.c asl_util.c asl_common.c asl_memory.c

LIBADD=	BlocksRuntime dispatch launch mach notify util

MAN=	asl.3 syslog.3

asl_ipcUser.h asl_ipcUser.c: asl_ipc.defs
	${MIG} ${MIG_FLAGS} -header asl_ipcUser.h -user asl_ipcUser.c ${.CURDIR}/asl_ipc.defs

asl.c: asl_ipcUser.h

CLEANFILES+=	asl_ipcUser.h

INCS=	asl.h

.include <bsd.lib.mk>
