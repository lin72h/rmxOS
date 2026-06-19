.include <bsd.init.mk>

LIB=	mach


A= ${.CURDIR}/${MACHINE_CPUARCH}
DEFS=${.CURDIR}/../../sys/compat/mach/defs


.PATH: ${.CURDIR}/mach
.PATH: ${A}
.PATH: ${A}/sys

.for _dir in ${.CURDIR}/../.. ${.CURDIR}/../../sys ${.CURDIR}/../../.. /sys /usr/src/sys
.if !defined(SYSDIR) && exists(${_dir}/kern/)
SYSDIR=	${_dir}
.endif
.endfor
.if !defined(SYSDIR) || !exists(${SYSDIR}/kern/)
.error "can't find kernel source tree"
.endif

CFLAGS+= -I${.CURDIR}/../../include -I. -I${A} -I${.CURDIR} -I./include
CFLAGS+= -I${SYSDIR} -I${.CURDIR}/../../apsl/include
CFLAGS+= -fPIC -DPRIVATE -D__MigTypeCheck=1 -DLIBSYSCALL_INTERFACE=1
CFLAGS+= -Wno-error=deprecated-non-prototype
CFLAGS+= -Wno-error=unused-but-set-variable
CFLAGS+= -Wno-error=missing-prototypes
CFLAGS+= -Wno-error=strict-prototypes
DEBUG_FLAGS= -g -O0
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${OBJTOP}/usr.bin/migcom/migcom
mach_port.h mach_portUser.c: ${DEFS}/mach_port.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/mach_port.defs
task.h taskUser.c: ${DEFS}/task.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/task.defs
host_priv.h host_privUser.c: ${DEFS}/host_priv.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/host_priv.defs
mach_host.h mach_hostUser.c: ${DEFS}/mach_host.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/mach_host.defs
vm_map.h vm_mapUser.c: ${DEFS}/vm_map.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/vm_map.defs
mach_vm.h mach_vmUser.c: ${DEFS}/mach_vm.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/mach_vm.defs
clock.h clockUser.c: ${DEFS}/clock.defs
	${MIG} ${CFLAGS} -server /dev/null ${DEFS}/clock.defs
SRCS=					\
	clockUser.c			\
	mach_portUser.c		\
	taskUser.c			\
	host_privUser.c		\
	mach_hostUser.c		\
	vm_mapUser.c		\
	mach_vmUser.c		\
	error_codes.c		\
	mach_error_string.c \
	mach_init.c 		\
	mach_msg.c			\
	mach_misc.c			\
	mig_allocate.c 		\
	mig_deallocate.c 	\
	mig_reply_setup.c	\
	mig_strncpy.c 		\
	mig_support.c

CLEANFILES+= machine *~ mach_port.h task.h host_priv.h mach_host.h
CLEANFILES+= cscope.* vm_map.h *User.c

.include <bsd.lib.mk>
