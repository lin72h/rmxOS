.include <src.opts.mk>
PROG= asld
NO_WERROR=yes
FILESGROUPS+= LAUNCHD
LAUNCHD= com.apple.syslogd.plist
LAUNCHDDIR= /etc/launchd.d
LAUNCHDMODE= 0644
CONFGROUPS= CONFS SYSLOGD_D
CONFS= ${SRCTOP}/etc/asl.conf ${SRCTOP}/etc/syslog.conf
SYSLOGD_D=
SYSLOGD_DDIR= /etc/syslog.d
.if ${MK_LPR} != "no"
CONFGROUPS+= LP
LP= ${SRCTOP}/usr.sbin/syslogd/lpr.conf
LPDIR= /etc/syslog.d
.endif
.if ${MK_PPP} != "no"
CONFGROUPS+= PPP
PPP= ${SRCTOP}/usr.sbin/syslogd/ppp.conf
PPPDIR= /etc/syslog.d
.endif

.PATH: .
.PATH: ${.CURDIR}
.PATH: ${.CURDIR}/support
.PATH: ${.CURDIR}/uuid
.PATH: ${.CURDIR}/init


MAN= asl.conf.5 syslog.conf.5 asld.8 syslogd.8

BASE_INCLUDE=  -I. -I${.CURDIR} -I${.CURDIR}/init -I${.CURDIR}/../../include/apple
BASE_INCLUDE+= -I${.CURDIR}/../../include -I${.CURDIR}/../../sys
DEFINES= -D__APPLE__ -fblocks -DLIBC_NO_LIBCRASHREPORTERCLIENT -DPRIVATE
MIG_FLAGS= ${BASE_INCLUDE} 	${DEFINES}
#override default CFLAGS
CFLAGS= ${MIG_FLAGS}  -D__MigTypeCheck
CFLAGS+= -I${.CURDIR}/../../contrib/openbsm -I${.CURDIR}/../../lib/liblaunch -I${.CURDIR}/../../lib/libasl -I${.CURDIR}/../../lib/libdispatch
CFLAGS+= -I${.CURDIR}/../../lib/libxpc -I${.CURDIR}/../../lib/libosxsupport -I${.CURDIR}/../../lib/libnotify
CFLAGS+= -include ${.CURDIR}/../notifyd/rmx_build_compat.h
CFLAGS+= -DHAVE_INTTYPES_H
CFLAGS+= -Wno-error=strict-prototypes
CFLAGS+= -Wno-error=deprecated-non-prototype
CFLAGS+= -Wno-error=missing-prototypes
CFLAGS+= -Wno-error=missing-variable-declarations
CFLAGS+= -Wno-error=unused-parameter
CFLAGS+= -Wno-error=unused-variable
CFLAGS+= -Wno-error=unused-but-set-variable
CFLAGS+= -Wno-error=sign-compare
CFLAGS+= -Wno-error=cast-qual
CFLAGS+= -Wno-error=shadow
CFLAGS+= -Wno-error=format
CFLAGS+= -Wno-error=tautological-pointer-compare
CFLAGS+= -Wno-error=incompatible-pointer-types-discards-qualifiers
CFLAGS+= -Wno-error=incompatible-pointer-types
CFLAGS+= -Wno-error=uninitialized
.if defined(SYSROOT) && !empty(SYSROOT)
MIGCOM?= ${SYSROOT}/usr/bin/migcom
.else
MIGCOM?= ${OBJTOP}/usr.bin/migcom/migcom
.endif
MIG?= sh ${.CURDIR}/../../usr.bin/migcom/mig.sh -migcom ${MIGCOM}

asl_ipc.h asl_ipcServer.c: ${.CURDIR}/../../lib/libasl/asl_ipc.defs 
	${MIG} ${MIG_FLAGS} -sheader asl_ipc.h ${.CURDIR}/../../lib/libasl/asl_ipc.defs

OBJLIB= ${OBJTOP}/lib

SRCS= startup_error.c telemetry.c asl_ipcServer.c asl_action.c bsd_in.c bsd_out.c daemon.c syslog_input.c input_io.c dbserver.c klog_in.c remote.c syslogd.c udp_in.c
LIBADD=	asl notify launch xpc dispatch osxsupport mach thr sys bsm auditd \
	BlocksRuntime nv sbuf util

FILESGROUPS+= LAUNCHD
LAUNCHD= com.apple.syslogd.plist
LAUNCHDDIR= /etc/launchd.d
LAUNCHDMODE= 0644

HAS_TESTS=
SUBDIR.${MK_TESTS}+= tests

.include <bsd.prog.mk>
