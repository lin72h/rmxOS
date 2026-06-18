.include <bsd.init.mk>
LIB=	osxsupport

.PATH: .
.PATH: ${.CURDIR}/uuid
.PATH: ../../sbin/launchd

BASE_INCLUDE= -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys -I${.CURDIR}
BASE_INCLUDE+= -I${.CURDIR}/../libasl
BASE_INCLUDE+= -I${.CURDIR}/../libdispatch
DEFINES= -D__APPLE__ -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
CFLAGS+= ${MIG_FLAGS}  -DHAVE_INTTYPES_H -fblocks

# Support surfaces needed by the imported launch/notify stack. The donor
# search/cache/file modules add a libnotify dependency cycle, so keep them
# out until that subsystem is brought up deliberately.
SRCS+= assumes.c libproc.c getiopolicy_np.c fileport.c pthread_qos_shim.c

#uuid
SRCS+= clear.c copy.c gen_uuid.c isnull.c unparse.c pack.c unpack.c


CLEANFILES+= *~ cscope.*

.include <bsd.lib.mk>
