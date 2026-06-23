.include <bsd.init.mk>

LIB= dispatch
NO_WERROR= yes

.PATH: ${.CURDIR}
.PATH: ${.CURDIR}/dispatch
.PATH: ${.CURDIR}/private
.PATH: ${.CURDIR}/src
.PATH: ${.CURDIR}/resolver

CFLAGS+=	-I${.CURDIR}/../../include/apple -I${.CURDIR}/os -I${.CURDIR}/private
CFLAGS+=	-I${.CURDIR} -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
CFLAGS+=	-I. -I${.CURDIR}/include -fblocks -fcommon
CFLAGS+=	-D__APPLE__ -DDISPATCH_USE_DTRACE=1
CFLAGS+=	-DDISPATCH_USE_DTRACE_INTROSPECTION=0
CFLAGS+=	-DDISPATCH_USE_SIMPLE_ASL=0 -DUSE_OBJC=0 -D__BLOCKS__=1
CFLAGS+=	-DDISPATCH_DEBUG=1
CFLAGS+=	-DOS_OBJECT_USE_OBJC=0
CFLAGS+=	-D__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__=101000
CFLAGS+=	-DHAVE__PTHREAD_WORKQUEUE_INIT=1 -DHAVE_PTHREAD_QOS_H=1
CFLAGS+=	-DDISPATCH_USE_NANOZONE=0
CFLAGS+=	-DDISPATCH_USE_LEGACY_WORKQUEUE_FALLBACK=0
CFLAGS+=	-DNXPLATFORM_DISPATCH_TWQ_WORKQUEUE=1
CFLAGS+=	-include ${.CURDIR}/src/freebsd_compat.h
CFLAGS+=	-Wno-error=switch
CFLAGS+=	-Wno-error=constant-conversion
CFLAGS+=	-Wno-error=strict-prototypes
CFLAGS+=	-Wno-error=format
CFLAGS+=	-Wno-error=void-pointer-to-int-cast
CFLAGS+=	-Wno-error=unused-function
CFLAGS+=	-Wno-error=unused-but-set-variable

LIBADD=	BlocksRuntime mach thr sys

MIGFLAGS=	-I. -I${.CURDIR}/../../include/apple
MIGFLAGS+=	-I${.CURDIR}/os -I${.CURDIR}/private -I${.CURDIR}
MIGFLAGS+=	-I${.CURDIR}/../../include
MIGFLAGS+=	-I${.CURDIR}/../../sys -I${.CURDIR}/include
MIGFLAGS+=	-D__APPLE__ -DPRIVATE -fblocks
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${OBJTOP}/usr.bin/migcom/migcom

protocolServer.c protocolUser.c protocol.h protocolServer.h: ${.CURDIR}/src/protocol.defs 
	${MIG} ${MIGFLAGS}  -user protocolUser.c \
	-server protocolServer.c -header protocol.h \
	-sheader protocolServer.h ${.CURDIR}/src/protocol.defs

SRCS =  protocolUser.c \
	protocolServer.c \
	allocator.c \
	apply.c	\
	benchmark.c \
	data.c \
	init.c \
	introspection.c	\
	io.c \
	object.c \
	once.c \
	queue.c \
	semaphore.c \
	source.c \
	time.c \
	transform.c \
	voucher.c \
	freebsd_kevent64.c \
	resolver.c \
	provider.d

INCSDIR= ${INCLUDEDIR}/dispatch
INCS=	base.h \
	block.h \
	data.h \
	dispatch.h \
	group.h \
	introspection.h \
	io.h \
	object.h \
	once.h \
	private.h \
	queue.h \
	semaphore.h \
	source.h \
	time.h

INCS+=	benchmark.h \
	data_private.h \
	introspection_private.h \
	io_private.h \
	layout_private.h \
	mach_private.h \
	queue_private.h \
	source_private.h \
	voucher_activity_private.h \
	voucher_private.h

INCSGROUPS=	INCS DISPATCHPRIVATEINCS
DISPATCHPRIVATEINCSDIR=	${INCLUDEDIR}/private
DISPATCHPRIVATEINCS= \
	${.CURDIR}/private/benchmark.h \
	${.CURDIR}/private/data_private.h \
	${.CURDIR}/private/io_private.h \
	${.CURDIR}/private/layout_private.h \
	${.CURDIR}/private/mach_private.h \
	${.CURDIR}/private/private.h \
	${.CURDIR}/private/queue_private.h \
	${.CURDIR}/private/source_private.h

CLEANFILES+= protocol.h protocolServer.c protocolServer.h protocolUser.c

.include <bsd.lib.mk>
