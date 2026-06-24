/*-
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef _SYS_THRWORKQ_H_
#define _SYS_THRWORKQ_H_

#include <sys/cdefs.h>
#include <sys/_types.h>
#include <sys/_stdint.h>

#define	TWQ_OP_INIT			0x001
#define	TWQ_OP_THREAD_ENTER		0x002
#define	TWQ_OP_THREAD_RETURN		0x004
#define	TWQ_OP_THREAD_TRANSFER		0x008
#define	TWQ_OP_REQTHREADS		0x020
#define	TWQ_OP_REQTHREADS2		0x030
#define	TWQ_OP_SHOULD_NARROW		0x200
#define	TWQ_OP_SETUP_DISPATCH		0x400

#define	TWQ_SWCB_BLOCK			1
#define	TWQ_SWCB_UNBLOCK		2

#define	TWQ_FEATURE_DISPATCHFUNC	0x01
#define	TWQ_FEATURE_FINEPRIO		0x02
#define	TWQ_FEATURE_MAINTENANCE		0x10
#define	TWQ_FEATURE_KEVENT		0x40
#define	TWQ_FEATURE_WORKLOOP		0x80

#define	TWQ_NUM_BUCKETS			6
#define	TWQ_BUCKET_MAINTENANCE		0
#define	TWQ_BUCKET_BACKGROUND		1
#define	TWQ_BUCKET_UTILITY		2
#define	TWQ_BUCKET_DEFAULT		3
#define	TWQ_BUCKET_USER_INITIATED	4
#define	TWQ_BUCKET_USER_INTERACTIVE	5

#define	TWQ_SPI_VERSION_NARROW		20160427U
#define	TWQ_SPI_VERSION_CURRENT		20170201U

#define	TWQ_DISPATCH_CONFIG_VERSION	2U
#define	TWQ_DISPATCH_MIN_VERSION	1U
#define	TWQ_DISPATCH_SUPPORTED_FLAGS	0U

#define	TWQ_INIT_VERSION		1U
#define	TWQ_INIT_SUPPORTED_FLAGS	0U

#define	TWQ_REQTHREADS_VERSION		1U
#define	TWQ_REQTHREADS_SUPPORTED_FLAGS	0U

#define	TWQ_THREAD_TRANSFER_VERSION	1U
#define	TWQ_THREAD_TRANSFER_SUPPORTED_FLAGS 0U

#define	TWQ_SHOULD_NARROW_VERSION	1U
#define	TWQ_SHOULD_NARROW_SUPPORTED_FLAGS 0U

#define	TWQ_PRIORITY_OVERCOMMIT_FLAG	0x80000000U
#define	TWQ_PRIORITY_SCHED_PRI_FLAG	0x20000000U
#define	TWQ_PRIORITY_COOPERATIVE_FLAG	0x08000000U
#define	TWQ_PRIORITY_EVENT_MANAGER_FLAG	0x02000000U
#define	TWQ_PRIORITY_FLAGS_MASK		0xff000000U
#define	TWQ_PRIORITY_QOS_CLASS_MASK	0x00ffff00U
#define	TWQ_PRIORITY_QOS_CLASS_SHIFT	8U
#define	TWQ_PRIORITY_PRIORITY_MASK	0x000000ffU

#define	TWQ_QOS_CLASS_UNSPECIFIED	0x00U
#define	TWQ_QOS_CLASS_MAINTENANCE	0x05U
#define	TWQ_QOS_CLASS_BACKGROUND	0x09U
#define	TWQ_QOS_CLASS_UTILITY		0x11U
#define	TWQ_QOS_CLASS_DEFAULT		0x15U
#define	TWQ_QOS_CLASS_USER_INITIATED	0x19U
#define	TWQ_QOS_CLASS_USER_INTERACTIVE	0x21U

typedef uint64_t twq_priority_t;

struct twq_init_args {
	uint32_t	tqi_version;
	uint32_t	tqi_flags;
	uint32_t	tqi_requested_features;
	uint32_t	tqi_reserved;
	uint64_t	tqi_dispatch_func;
	uint64_t	tqi_stack_size;
	uint64_t	tqi_guard_size;
} __packed;

struct twq_reqthreads_args {
	uint32_t	tqr_version;
	uint32_t	tqr_flags;
	uint32_t	tqr_reqcount;
	uint32_t	tqr_reserved;
	uint64_t	tqr_priority;
} __packed;

struct twq_thread_transfer_args {
	uint32_t	tqt_version;
	uint32_t	tqt_flags;
	uint32_t	tqt_from_reqcount;
	uint32_t	tqt_reserved;
	uint64_t	tqt_from_priority;
	uint64_t	tqt_to_priority;
} __packed;

struct twq_should_narrow_args {
	uint32_t	tqn_version;
	uint32_t	tqn_flags;
	uint32_t	tqn_reserved0;
	uint32_t	tqn_reserved1;
	uint64_t	tqn_priority;
} __packed;

struct twq_dispatch_config {
	uint32_t	version;
	uint32_t	flags;
	uint64_t	queue_serialno_offs;
	uint64_t	queue_label_offs;
} __packed;

#ifdef _KERNEL
struct proc;
struct thread;

void	twq_proc_exec(struct proc *p);
void	twq_proc_exit(struct proc *p);
void	twq_thread_exit(struct thread *td);
void	twq_thread_switch(struct thread *td, int type, int flags);
#else
int	twq_kernreturn(int op, void *arg2, int arg3, int arg4);
#endif

#endif /* !_SYS_THRWORKQ_H_ */
