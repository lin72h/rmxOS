.include <bsd.own.mk>

PROG= launchctl
MAN= launchctl.1
MK_PIE= no

BASE_INCLUDE= -I${.CURDIR}/../../include/apple

CFLAGS+= ${BASE_INCLUDE} -fblocks
CFLAGS+= -I${.CURDIR}/../../lib/liblaunch
CFLAGS+= -I${.CURDIR}/../../lib/libxpc
CFLAGS+= -I${.CURDIR}/../../lib/libdispatch
CFLAGS+= -I${.CURDIR}/../../lib/libdispatch/private
CFLAGS+= -I${.CURDIR}/../../sbin/launchd
CFLAGS+= -I${.CURDIR}/../../contrib/jansson/src
CFLAGS+= -I${.CURDIR}/../../lib/libjansson
CFLAGS+= -I${.CURDIR}/../../include/mach
CFLAGS+= -I${.CURDIR}/../../sys
CFLAGS+= -idirafter ${.CURDIR}/../../include
# libmach owns the process bootstrap_port; launchctl carries an unused legacy
# definition that otherwise collides under FreeBSD's -fno-common build.
CFLAGS+= -Dbootstrap_port=launchctl_bootstrap_port
.if defined(NXPLATFORM_MACH_PREFIX)
CFLAGS+= -I${NXPLATFORM_MACH_PREFIX}/include
CFLAGS+= -I${NXPLATFORM_MACH_PREFIX}/include/apple
.endif

OBJLIB= ${OBJTOP}/lib
LDADD+= -Wl,--start-group
LDADD+= ${OBJLIB}/liblaunch/liblaunch.a
LDADD+= ${OBJLIB}/libjansson/libjansson.a
LDADD+= ${OBJLIB}/libexpat/libbsdxml.a
LDADD+= ${OBJLIB}/libxpc/libxpc.a
LDADD+= ${OBJLIB}/libdispatch/libdispatch.a
LDADD+= ${OBJLIB}/libosxsupport_rmx/libosxsupport.a
LDADD+= ${OBJLIB}/libmach/libmach.a
LDADD+= ${OBJLIB}/libthr/libthr.a
LDADD+= ${OBJLIB}/libsys/libsys.a
LDADD+= ${OBJLIB}/libc/libc.a
LDADD+= ${OBJLIB}/libblocksruntime/libBlocksRuntime.a
LDADD+= ${OBJLIB}/libnv/libnv.a
LDADD+= ${OBJLIB}/libsbuf/libsbuf.a
LDADD+= ${OBJLIB}/libutil/libutil.a
LDADD+= -Wl,--end-group
SRCS= launchctl.c plist_to_launch_data.c

.include <bsd.prog.mk>
