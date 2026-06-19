PROG= launchd

.PATH: .
.PATH: ${.CURDIR}
.PATH: ${.CURDIR}/support
.PATH: ${.CURDIR}/uuid
.PATH: ${.CURDIR}/init


BASE_INCLUDE=  -I. -I${.CURDIR} -I${.CURDIR}/init -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys -I${MACHINE_INCLUDES}
DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${OBJTOP}/usr.bin/migcom/migcom
#override default CFLAGS
CFLAGS= ${MIG_FLAGS}  -D__MigTypeCheck
CFLAGS+= -I${.CURDIR}/../../contrib/openbsm -I${.CURDIR}/../../lib/liblaunch
CFLAGS+= -I${.CURDIR}/../../lib/libxpc
CFLAGS+= -I${.CURDIR}/../../lib/libdispatch
CFLAGS+= -I${.CURDIR}/../../lib/libdispatch/private
CFLAGS+= -I${.CURDIR}/../../lib/libosxsupport
CFLAGS+= -I${.CURDIR}/../../lib/libasl
CFLAGS+= -DHAVE_INTTYPES_H
CFLAGS+= -include Availability.h
CFLAGS+= -include mach/boolean.h
CFLAGS+= -include rmx_build_compat.h
CFLAGS+= -Wno-error=unused-but-set-variable
CFLAGS+= -Wno-error=shift-negative-value
CFLAGS+= -Wno-error=pointer-integer-compare
CFLAGS+= -Wno-error=missing-prototypes
CFLAGS+= -Wno-error=frame-address
CFLAGS+= -Wno-error=incompatible-pointer-types
CFLAGS+= -Wno-error=deprecated-non-prototype
# Darwin kernel-event sockets are compile-time compatible here; socket failure
# remains handled by launchd when the domain is not implemented.
CFLAGS+= -DAF_SYSTEM=43 -DPF_SYSTEM=AF_SYSTEM
# These NOTE_* values match the NextBSD donor event.h surface. They let this
# build-only bringup compile without changing the canonical kernel header.
CFLAGS+= -DNOTE_EXITSTATUS=0x04000000 -DNOTE_EXIT_DETAIL=0x02000000
CFLAGS+= -DNOTE_EXIT_DECRYPTFAIL=0x00010000 -DNOTE_EXIT_MEMORY=0x00020000
CFLAGS+= -DNOTE_ABSOLUTE=0x00000010 -DNOTE_SIGNAL=0x08000000
CFLAGS+= -D__DARWIN_UUID_COMPARE

DEBUG_FLAGS+= -g -O0

NO_WERROR=

helper.h launchd_helperServer.h: ${.CURDIR}/helper.defs
	${MIG} ${MIG_FLAGS} -user /dev/null -server /dev/null -header helper.h \
	-sheader launchd_helperServer.h ${.CURDIR}/helper.defs

jobServer.h jobServer.c job.h: ${.CURDIR}/job.defs helper.h
	${MIG} ${MIG_FLAGS} -sheader jobServer.h ${.CURDIR}/job.defs
job_reply.h job_replyUser.c job_replyServer.c job_replyServer.h: ${.CURDIR}/job_reply.defs
	${MIG} ${MIG_FLAGS} -header job_reply.h -sheader job_replyServer.h ${.CURDIR}/job_reply.defs
${.CURDIR}/job_forward.h job_forwardUser.c job_forwardServer.h: ${.CURDIR}/job_forward.defs
	${MIG} ${MIG_FLAGS} -header job_forward.h -sheader job_forwardServer.h ${.CURDIR}/job_forward.defs
notify.h notifyServer.c notifyServer.h: ${.CURDIR}/notify.defs
	${MIG} ${MIG_FLAGS} -header notify.h -sheader notifyServer.h ${.CURDIR}/notify.defs
mach_excServer.h mach_excServer.c: ${.CURDIR}/mach_exc.defs
	${MIG} ${MIG_FLAGS} -sheader mach_excServer.h ${.CURDIR}/mach_exc.defs
internal.h internalServer.h internalServer.c internalUser.c: ${.CURDIR}/internal.defs
	${MIG} ${MIG_FLAGS} -header internal.h -sheader internalServer.h ${.CURDIR}/internal.defs



SRCS= jobServer.c mach_excServer.c internalServer.c
SRCS+= job_forwardUser.c  job_replyUser.c job_replyServer.c notifyServer.c
SRCS+= internalUser.c
SRCS+= launchd.c core.c kill2.c ktrace.c ipc.c log.c runtime.c
SRCS+= init.c

LIBADD=	launch asl notify xpc dispatch osxsupport mach thr sys bsm auditd \
	BlocksRuntime nv sbuf util


MAN=	launchd.conf.5 launchd.plist.5 launchd.8

launchd.1:
	MAN=

CLEANFILES+= *Server.c *User.c job.h helper.h job_reply.h job_forward.h notify.h \
	internal.h mach_exc.h *Server.h *~ cscope.*
.include <bsd.prog.mk>
