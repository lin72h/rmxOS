.include <src.opts.mk>
PROG= notifyd
NO_WERROR= yes
MK_PIE= no

.PATH: .
.PATH: ${.CURDIR}
.PATH: ${.CURDIR}/support
.PATH: ${.CURDIR}/uuid
.PATH: ${.CURDIR}/init


MK_MAN= no

BASE_INCLUDE=  -I. -I${.CURDIR} -I${.CURDIR}/init -I${.CURDIR}/../../include/apple -I${MACHINE_INCLUDES}
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
BASE_INCLUDE+= -I${.CURDIR}/../../lib/libnotify -I${.CURDIR}/../../lib/liblaunch
BASE_INCLUDE+= -I${.CURDIR}/../../lib/libdispatch -I${.CURDIR}/../../lib/libasl
BASE_INCLUDE+= -I${.CURDIR}/../../lib/libxpc -I${.CURDIR}/../../lib/libosxsupport
DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
#override default CFLAGS
CFLAGS= ${MIG_FLAGS}  -D__MigTypeCheck -fcommon
CFLAGS+= -I${.CURDIR}/../../contrib/openbsm
CFLAGS+= -DHAVE_INTTYPES_H

DEBUG_FLAGS+= -g -O0

OBJLIB= ${OBJTOP}/lib

notify_ipc.h notify_ipcServer.c: ${.CURDIR}/../../lib/libnotify/notify_ipc.defs
	mig ${MIG_FLAGS} ${.CURDIR}/../../lib/libnotify/notify_ipc.defs

notify_proc: notify_ipcServer.c

LDADD+= -Wl,--start-group
LDADD+= ${OBJLIB}/libnotify/libnotify.a
LDADD+= ${OBJLIB}/liblaunch/liblaunch.a
LDADD+= ${OBJLIB}/libxpc/libxpc.a
LDADD+= ${OBJLIB}/libdispatch/libdispatch.a
LDADD+= ${OBJLIB}/libosxsupport/libosxsupport.a
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
LDADD+= -Wl,--end-group
SRCS=notify_proc.c notifyd.c service.c timer.c n2_markers.c notify_ipcServer.c


CLEANFILES+= *Server.c *User.c job.h helper.h job_reply.h job_forward.h notify.h \
	internal.h mach_exc.h *Server.h *~ cscope.*
.include <bsd.prog.mk>
