.include <bsd.init.mk>

LIB=	osxsupport

DONOR_OSXSUPPORT=	${SRCTOP}/lib/libosxsupport

.PATH: ${DONOR_OSXSUPPORT}
.PATH: ${DONOR_OSXSUPPORT}/uuid
.PATH: ${SRCTOP}/sbin/launchd
.PATH: ${.CURDIR}

BASE_INCLUDE=	-I${SRCTOP}/include/apple
BASE_INCLUDE+=	-I${SRCTOP}/include -I${SRCTOP}/sys -I${DONOR_OSXSUPPORT}
BASE_INCLUDE+=	-I${SRCTOP}/lib/libasl
BASE_INCLUDE+=	-I${SRCTOP}/lib/libdispatch
DEFINES=	-D__APPLE__ -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
CFLAGS+=	${BASE_INCLUDE} ${DEFINES} -DHAVE_INTTYPES_H -fblocks
CFLAGS+=	-Wno-error=missing-prototypes
LIBADD=	sys

# Keep lib/libosxsupport byte-identical to the donor tree. Gate the
# search/cache/plugin modules here until their dependencies are brought up:
# si_module.c search_module.c si_data.c cache_module.c file_module.c.
# The donor also carries mdns_module.c and si_getaddrinfo.c as unbuilt source.
SRCS+=	assumes.c libproc.c getiopolicy_np.c fileport.c pthread_qos_shim.c
SRCS+=	libinfo_cache_shim.c uuid_compare_shim.c
SRCS+=	clear.c copy.c gen_uuid.c isnull.c unparse.c pack.c unpack.c

CLEANFILES+=	*~ cscope.*

.include <bsd.lib.mk>
