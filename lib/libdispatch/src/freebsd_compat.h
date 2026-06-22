#ifndef RMX_LIBDISPATCH_FREEBSD_COMPAT_H
#define RMX_LIBDISPATCH_FREEBSD_COMPAT_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/event.h>
#include <time.h>

#include <mach/port.h>

#if defined(NXPLATFORM_DISPATCH_TWQ_WORKQUEUE)
#include <Availability.h>
#include <pthread.h>
#include <pthread/qos.h>

#if !defined(__MAC_OS_X_VERSION_MIN_REQUIRED) || \
    __MAC_OS_X_VERSION_MIN_REQUIRED < 101000
#error "NXPLATFORM_DISPATCH_TWQ_WORKQUEUE requires __MAC_OS_X_VERSION_MIN_REQUIRED >= 101000"
#endif

int pthread_attr_get_qos_class_np(const pthread_attr_t *, qos_class_t *, int *);
int pthread_attr_set_qos_class_np(pthread_attr_t *, qos_class_t, int);
#endif

/*
 * The selected FreeBSD 15.1 kernel tree registers EVFILT_MACHPORT at -16 and
 * bumps EVFILT_SYSCOUNT to 16. Some userland header sets lag that kernel
 * pairing, so keep dispatch's private filter numbering coherent here.
 */
#ifndef EVFILT_MACHPORT
#define EVFILT_MACHPORT (-16)
#endif

#if EVFILT_SYSCOUNT < 16
#undef EVFILT_SYSCOUNT
#define EVFILT_SYSCOUNT 16
#endif

#ifndef NOTE_VM_PRESSURE
#define NOTE_VM_PRESSURE 0x80000000
#endif

#ifndef NOTE_ABSOLUTE
#ifdef NOTE_ABSTIME
#define NOTE_ABSOLUTE NOTE_ABSTIME
#else
#define NOTE_ABSOLUTE 0x00000010
#endif
#endif

#ifndef EV_SET64
struct kevent64_s {
	uint64_t ident;
	int16_t filter;
	uint16_t flags;
	uint32_t fflags;
	int64_t data;
	uint64_t udata;
	uint64_t ext[2];
};

#define EV_SET64(kevp, a, b, c, d, e, f, g, h) do {	\
	struct kevent64_s *__kevp = (kevp);		\
	__kevp->ident = (a);				\
	__kevp->filter = (b);				\
	__kevp->flags = (c);				\
	__kevp->fflags = (d);				\
	__kevp->data = (e);				\
	__kevp->udata = (uint64_t)(uintptr_t)(f);	\
	__kevp->ext[0] = (g);				\
	__kevp->ext[1] = (h);				\
} while (0)

int _dispatch_kevent64(int kq, const struct kevent64_s *changelist,
    int nchanges, struct kevent64_s *eventlist, int nevents,
    unsigned int flags, const struct timespec *timeout)
    __attribute__((visibility("hidden")));
#define kevent64 _dispatch_kevent64
#endif

mach_port_t pthread_mach_thread_np(uintptr_t);

/*
 * The donor QoS workqueue path assumes Darwin direct TSD exposes a dedicated
 * dispatch_priority_key. The Phase 0.7 FreeBSD lane uses pthread keys instead;
 * alias the current-priority lookup to the default-priority key for the P5
 * staged-workqueue smoke.
 */
#if defined(NXPLATFORM_DISPATCH_TWQ_WORKQUEUE)
#ifndef QOS_CLASS_LEGACY
#define QOS_CLASS_LEGACY QOS_CLASS_DEFAULT
#endif
#define dispatch_priority_key dispatch_defaultpriority_key
#endif

#endif
