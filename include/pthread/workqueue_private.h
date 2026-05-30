/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026
 */

#ifndef _PTHREAD_WORKQUEUE_PRIVATE_H_
#define _PTHREAD_WORKQUEUE_PRIVATE_H_

#include <sys/cdefs.h>
#include <sys/types.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <pthread.h>

#ifndef _PTHREAD_PRIORITY_T_DECLARED
#define _PTHREAD_PRIORITY_T_DECLARED
typedef uint64_t pthread_priority_t;
#endif

#define PTHREAD_WORKQUEUE_SPI_VERSION 20170201U

#define WORKQ_FEATURE_DISPATCHFUNC 0x01
#define WORKQ_FEATURE_FINEPRIO 0x02
#define WORKQ_FEATURE_MAINTENANCE 0x10
#define WORKQ_FEATURE_KEVENT 0x40
#define WORKQ_FEATURE_WORKLOOP 0x80

#define WORKQ_NUM_PRIOQUEUE 4

#define WORKQ_HIGH_PRIOQUEUE 0
#define WORKQ_DEFAULT_PRIOQUEUE 1
#define WORKQ_LOW_PRIOQUEUE 2
#define WORKQ_BG_PRIOQUEUE 3
#define WORKQ_NON_INTERACTIVE_PRIOQUEUE 128

#define WORKQ_ADDTHREADS_OPTION_OVERCOMMIT 0x00000001

typedef void (*pthread_workqueue_function_t)(int queue_priority, int options,
    void *ctxt);
typedef void (*pthread_workqueue_function2_t)(pthread_priority_t priority);
typedef void (*pthread_workqueue_function_kevent_t)(void **events, int *nevents);
typedef void (*pthread_workqueue_function_workloop_t)(uint64_t *workloop_id,
    void **events, int *nevents);

#define PTHREAD_WORKQUEUE_CONFIG_VERSION 2U
#define PTHREAD_WORKQUEUE_CONFIG_MIN_SUPPORTED_VERSION 1U
#define PTHREAD_WORKQUEUE_CONFIG_SUPPORTED_FLAGS 0U

struct pthread_workqueue_config {
	uint32_t flags;
	uint32_t version;
	pthread_workqueue_function_kevent_t kevent_cb;
	pthread_workqueue_function_workloop_t workloop_cb;
	pthread_workqueue_function2_t workq_cb;
	uint64_t queue_serialno_offs;
	uint64_t queue_label_offs;
};

__BEGIN_DECLS

int	pthread_workqueue_setup(struct pthread_workqueue_config *cfg,
	    size_t cfg_size);
int	_pthread_workqueue_init(pthread_workqueue_function2_t func, int offset,
	    int flags);
int	_pthread_workqueue_init_with_kevent(
	    pthread_workqueue_function2_t queue_func,
	    pthread_workqueue_function_kevent_t kevent_func, int offset,
	    int flags);
int	_pthread_workqueue_init_with_workloop(
	    pthread_workqueue_function2_t queue_func,
	    pthread_workqueue_function_kevent_t kevent_func,
	    pthread_workqueue_function_workloop_t workloop_func, int offset,
	    int flags);
int	__pthread_workqueue_setkill(int enable);
int	pthread_workqueue_setdispatch_np(pthread_workqueue_function_t worker_func);
void	pthread_workqueue_setdispatchoffset_np(int offset);
int	pthread_workqueue_addthreads_np(int queue_priority, int options,
	    int numthreads);
int	_pthread_workqueue_supported(void);
int	_pthread_workqueue_addthreads(int numthreads,
	    pthread_priority_t priority);
bool	_pthread_workqueue_should_narrow(pthread_priority_t priority);
int	_pthread_workqueue_set_event_manager_priority(
	    pthread_priority_t priority);
int	_pthread_qos_override_start_direct(uint32_t thread,
	    pthread_priority_t priority, void *resource);
int	_pthread_qos_override_end_direct(uint32_t thread, void *resource);
int	_pthread_override_qos_class_start_direct(uint32_t thread,
	    pthread_priority_t priority);
int	_pthread_override_qos_class_end_direct(uint32_t thread);
int	_pthread_workqueue_override_start_direct(uint32_t thread,
	    pthread_priority_t priority);
int	_pthread_workqueue_override_start_direct_check_owner(uint32_t thread,
	    pthread_priority_t priority, uint32_t *ulock_addr);
int	_pthread_workqueue_override_reset(void);

__END_DECLS

#endif /* !_PTHREAD_WORKQUEUE_PRIVATE_H_ */
