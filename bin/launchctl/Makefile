.include <bsd.own.mk>

PROG= launchctl
MAN= launchctl.1

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
CFLAGS+= -idirafter ${.CURDIR}/../../include
.if defined(NXPLATFORM_MACH_PREFIX)
CFLAGS+= -I${NXPLATFORM_MACH_PREFIX}/include
CFLAGS+= -I${NXPLATFORM_MACH_PREFIX}/include/apple
.endif
LDFLAGS+= -llaunch -lmach -ldispatch
LDFLAGS+= -losxsupport -lBlocksRuntime -pthread
DPADD+= ${LIBJANSSON}
LDFLAGS+= -lutil
LDFLAGS+= -ljansson
LDFLAGS+= -lbsdxml
SRCS= launchctl.c plist_to_launch_data.c

.include <bsd.prog.mk>
