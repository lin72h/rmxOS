.include <bsd.init.mk>

LIB= xpc
NO_WERROR= yes

.PATH: ${.CURDIR}/xpc

BASE_INCLUDE= -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR}/../libnv
BASE_INCLUDE+= -I${.CURDIR} -I${.CURDIR}/../libdispatch -I${.CURDIR}/../liblaunch
BASE_INCLUDE+= -I${.CURDIR}/../../sbin/launchd -I.
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
CFLAGS+= ${BASE_INCLUDE} -fblocks -g -O0
CFLAGS+= -include ${.CURDIR}/../../sbin/launchd/rmx_build_compat.h
CFLAGS+= -Wno-error=missing-prototypes
CFLAGS+= -Wno-error=cast-qual
CFLAGS+= -Wno-error=incompatible-pointer-types-discards-qualifiers
CFLAGS+= -Wno-error=unused-variable
CFLAGS+= -Wno-error=uninitialized
CFLAGS+= -Wno-error=return-type
CFLAGS+= -Wno-error=unused-parameter
CFLAGS+= -Wno-error=unused-but-set-variable
CFLAGS+= -Wno-error=invalid-noreturn
CFLAGS+= -Wno-error=format
CFLAGS+= -Wno-error=incompatible-pointer-types
CFLAGS+= -Wno-error=unused-function
CFLAGS+= -Wno-error=strict-prototypes
CFLAGS+= -Wno-error=deprecated-non-prototype
CFLAGS+= -Wno-error=pointer-to-int-cast

SRCS=	xpc_dictionary.c \
	xpc_misc.c \
	xpc_type.c \
	xpc_array.c \
	xpc_connection.c \
	subr_nvlist.c \
	subr_nvpair.c

LIBADD=	BlocksRuntime dispatch launch mach bsm nv sbuf

INCSDIR= ${INCLUDEDIR}/xpc
INCS=	activity.h \
	base.h \
	connection.h \
	debug.h \
	endpoint.h \
	launchd.h \
	xpc.h

.include <bsd.lib.mk>
