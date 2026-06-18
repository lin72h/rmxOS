/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026
 */

#ifndef _PTHREAD_QOS_PRIVATE_H_
#define _PTHREAD_QOS_PRIVATE_H_

#include <sys/cdefs.h>
#include <sys/types.h>
#include <stdint.h>
#include <pthread/qos.h>

#ifndef _PTHREAD_PRIORITY_T_DECLARED
#define _PTHREAD_PRIORITY_T_DECLARED
typedef uint64_t pthread_priority_t;
#endif

typedef unsigned int _pthread_set_flags_t;

#define	_PTHREAD_SET_SELF_QOS_FLAG		0x1U
#define	_PTHREAD_SET_SELF_VOUCHER_FLAG		0x2U
#define	_PTHREAD_SET_SELF_FIXEDPRIORITY_FLAG	0x4U
#define	_PTHREAD_SET_SELF_TIMESHARE_FLAG	0x8U
#define	_PTHREAD_SET_SELF_WQ_KEVENT_UNBIND	0x10U
#define	_PTHREAD_SET_SELF_ALTERNATE_AMX		0x20U

#define	_PTHREAD_PRIORITY_OVERCOMMIT_FLAG	0x80000000U
#define	_PTHREAD_PRIORITY_INHERIT_FLAG		0x40000000U
#define	_PTHREAD_PRIORITY_SCHED_PRI_FLAG	0x20000000U
#define	_PTHREAD_PRIORITY_ENFORCE_FLAG		0x10000000U
#define	_PTHREAD_PRIORITY_FALLBACK_FLAG		0x04000000U
#define	_PTHREAD_PRIORITY_EVENT_MANAGER_FLAG	0x02000000U
#define	_PTHREAD_PRIORITY_NEEDS_UNBIND_FLAG	0x01000000U
#define	_PTHREAD_PRIORITY_FLAGS_MASK		0xff000000U
#define	_PTHREAD_PRIORITY_QOS_CLASS_MASK	0x00ffff00U
#define	_PTHREAD_PRIORITY_QOS_CLASS_SHIFT	8U
#define	_PTHREAD_PRIORITY_PRIORITY_MASK		0x000000ffU

#define	PTHREAD_MAX_PARALLELISM_PHYSICAL	0x1UL

__BEGIN_DECLS

pthread_priority_t	_pthread_qos_class_encode(qos_class_t qos_class,
			    int relative_priority, unsigned long flags);
qos_class_t		_pthread_qos_class_decode(pthread_priority_t priority,
			    int *relative_priority, unsigned long *flags);
pthread_priority_t	_pthread_qos_class_encode_workqueue(int queue_priority,
			    unsigned long flags);
int			_pthread_set_properties_self(_pthread_set_flags_t flags,
			    pthread_priority_t priority, uint32_t voucher);
int			pthread_qos_max_parallelism(qos_class_t qos,
			    unsigned long flags);
int			pthread_time_constraint_max_parallelism(
			    unsigned long flags);

__END_DECLS

#endif /* !_PTHREAD_QOS_PRIVATE_H_ */
