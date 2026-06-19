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

LIBADD=	launch jansson bsdxml xpc dispatch osxsupport mach thr sys bsm \
	BlocksRuntime nv sbuf util
SRCS= launchctl.c plist_to_launch_data.c

.include <bsd.prog.mk>
