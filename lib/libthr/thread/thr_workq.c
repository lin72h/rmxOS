/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026
 */

#include "namespace.h"
#include <sys/param.h>
#include <errno.h>
#include <pthread.h>
#include <pthread/qos_private.h>
#include <pthread/workqueue_private.h>
#include <pthread_workqueue.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "un-namespace.h"

#include "thr_workq_kern.h"
#include "thr_private.h"

__weak_reference(_pthread_workqueue_init, pthread_workqueue_init);
__weak_reference(_pthread_workqueue_init_with_kevent,
    pthread_workqueue_init_with_kevent);
__weak_reference(_pthread_workqueue_init_with_workloop,
    pthread_workqueue_init_with_workloop);
__weak_reference(_pthread_workqueue_supported, pthread_workqueue_supported);
__weak_reference(_pthread_workqueue_addthreads, pthread_workqueue_addthreads);
__weak_reference(_pthread_workqueue_should_narrow,
    pthread_workqueue_should_narrow);

struct twq_lane_runtime {
	uint32_t		tbr_pending;
	uint32_t		tbr_ready;
	uint32_t		tbr_active;
	uint32_t		tbr_idle;
	pthread_priority_t	tbr_priority;
};

struct twq_runtime {
	struct umutex		tr_lock;
	int			tr_configuring;
	int			tr_initialized;
	int			tr_reaper_started;
	int			tr_supported_checked;
	int			tr_supported_features;
	int			tr_dispatch_offset;
	uint64_t		tr_queue_serialno_offs;
	uint64_t		tr_queue_label_offs;
	uint64_t		tr_last_activity_msec;
	uint32_t		tr_init_features;
	pthread_workqueue_function_t tr_legacy_func;
	pthread_workqueue_function2_t tr_worker_func;
	uint32_t		tr_idle_workers;
	uint32_t		tr_live_workers;
	uint32_t		tr_retire_budget;
	volatile u_int		tr_wait_seq;
	struct twq_lane_runtime	tr_bucket[TWQ_NUM_BUCKETS * 2];
};

struct twq_worker {
	struct twq_runtime	*tw_runtime;
};

static struct twq_runtime twq_runtime = {
	.tr_lock = DEFAULT_UMUTEX,
	.tr_dispatch_offset = 0,
};

#define	TWQ_IDLE_TIMEOUT_SEC	5
#define	TWQ_REAPER_PERIOD_MSEC	100
#define	TWQ_RUNTIME_NUM_LANES	(TWQ_NUM_BUCKETS * 2)

static uint16_t twq_lane_desired_locked(struct twq_runtime *rt, int lane);
static int twq_kernel_sync_request(uint16_t desired,
    pthread_priority_t priority);
static int twq_kernel_thread_transfer(uint16_t from_desired,
    pthread_priority_t from_priority, pthread_priority_t to_priority);
static int twq_spawn_workers(struct twq_runtime *rt, uint16_t count);
static int twq_sys_kernreturn(int op, void *arg2, int arg3, int arg4);

static inline bool
twq_priority_is_overcommit(pthread_priority_t priority)
{

	return ((priority & TWQ_PRIORITY_OVERCOMMIT_FLAG) != 0);
}

static pthread_priority_t
twq_priority_for_kernel(pthread_priority_t priority)
{

	/*
	 * Donor libdispatch uses 0x20000000 as its internal root-queue flag.
	 * The TWQ kernel ABI uses the same bit as SCHED_PRI.  A root queue also
	 * carries a QoS token, while a SCHED_PRI request does not, so strip the
	 * colliding bit before kernel calls for QoS work.  Userspace lane
	 * selection applies the same QoS-token discriminator.
	 */
	if ((priority & TWQ_PRIORITY_QOS_CLASS_MASK) != 0)
		priority &= ~((pthread_priority_t)TWQ_PRIORITY_SCHED_PRI_FLAG);
	return (priority);
}

static inline int
twq_lane_make(int bucket, bool overcommit)
{

	return (bucket * 2 + (overcommit ? 1 : 0));
}

static inline int
twq_lane_bucket(int lane)
{

	return (lane / 2);
}

static inline bool
twq_lane_is_valid(int lane)
{

	return (lane >= 0 && lane < TWQ_RUNTIME_NUM_LANES);
}

static int twq_trace_checked;
static int twq_trace_enabled;

static bool
twq_trace_is_enabled(void)
{
	const char *env;

	if (!twq_trace_checked) {
		env = getenv("LIBPTHREAD_TWQ_TRACE");
		twq_trace_enabled = (env != NULL && env[0] != '\0' &&
		    strcmp(env, "0") != 0);
		twq_trace_checked = 1;
	}
	return (twq_trace_enabled != 0);
}

static void
twq_trace_event_locked(struct twq_runtime *rt, const char *event, int lane,
    pthread_priority_t priority, uint32_t requested, uint32_t admitted,
    uint32_t wake_needed, uint32_t spawn_needed)
{
	uint32_t active, lane_idle, pending, ready;
	int bucket;

	if (!twq_trace_is_enabled())
		return;
	if (twq_lane_is_valid(lane)) {
		bucket = twq_lane_bucket(lane);
		pending = rt->tr_bucket[lane].tbr_pending;
		ready = rt->tr_bucket[lane].tbr_ready;
		active = rt->tr_bucket[lane].tbr_active;
		lane_idle = rt->tr_bucket[lane].tbr_idle;
	} else {
		bucket = -1;
		pending = 0;
		ready = 0;
		active = 0;
		lane_idle = 0;
	}
	dprintf(2,
	    "[libthr-twq] event=%s tid=%llu lane=%d bucket=%d priority=0x%08x "
	    "pending=%u ready=%u active=%u lane_idle=%u idle_workers=%u "
	    "live_workers=%u requested=%u admitted=%u wake=%u spawn=%u "
	    "retire=%u wait_seq=%u\n",
	    event, (unsigned long long)(uintptr_t)_get_curthread(), lane, bucket,
	    (unsigned int)priority, pending, ready, active, lane_idle,
	    rt->tr_idle_workers, rt->tr_live_workers, requested, admitted,
	    wake_needed, spawn_needed, rt->tr_retire_budget, rt->tr_wait_seq);
}

static void
twq_trace_event(struct twq_runtime *rt, const char *event, int lane,
    pthread_priority_t priority, uint32_t requested, uint32_t admitted,
    uint32_t wake_needed, uint32_t spawn_needed)
{
	struct pthread *curthread;

	if (!twq_trace_is_enabled())
		return;
	curthread = _get_curthread();
	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	twq_trace_event_locked(rt, event, lane, priority, requested, admitted,
	    wake_needed, spawn_needed);
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
}

static uint32_t
twq_requested_features(void)
{

	return (WORKQ_FEATURE_DISPATCHFUNC | WORKQ_FEATURE_FINEPRIO |
	    WORKQ_FEATURE_MAINTENANCE);
}

static uint32_t
twq_probe_supported_features(void)
{
	struct twq_init_args init_args;
	uint32_t requested;
	int ret, saved_errno;

	requested = twq_requested_features();
	memset(&init_args, 0, sizeof(init_args));
	init_args.tqi_version = PTHREAD_WORKQUEUE_SPI_VERSION;
	init_args.tqi_requested_features = requested;
	init_args.tqi_stack_size = _pthread_attr_default.stacksize_attr;
	init_args.tqi_guard_size = _pthread_attr_default.guardsize_attr;

	saved_errno = errno;
	ret = twq_sys_kernreturn(TWQ_OP_INIT, &init_args, sizeof(init_args), 0);
	errno = saved_errno;
	if (ret == -1)
		return (0);
	return ((uint32_t)ret & requested);
}

static uint32_t
twq_warm_worker_floor(void)
{
	long cpus;

	cpus = sysconf(_SC_NPROCESSORS_ONLN);
	if (cpus < 1)
		return (1);
	if (cpus > 4)
		cpus = 4;
	return ((uint32_t)cpus);
}

static uint64_t
twq_now_msec(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((uint64_t)now.tv_sec * 1000ULL +
	    (uint64_t)now.tv_nsec / 1000000ULL);
}

static void
twq_note_activity_locked(struct twq_runtime *rt)
{

	rt->tr_last_activity_msec = twq_now_msec();
}

static bool
twq_any_pending_locked(struct twq_runtime *rt)
{
	int lane;

	for (lane = 0; lane < TWQ_RUNTIME_NUM_LANES; lane++) {
		if (rt->tr_bucket[lane].tbr_pending != 0)
			return (true);
	}
	return (false);
}

static int
twq_pick_redrive_lane_locked(struct twq_runtime *rt)
{
	int lane;

	for (lane = TWQ_RUNTIME_NUM_LANES - 1; lane >= 0; lane--) {
		if (rt->tr_bucket[lane].tbr_pending != 0 &&
		    rt->tr_bucket[lane].tbr_ready == 0)
			return (lane);
	}
	return (-1);
}

static void
twq_reaper_pause(void)
{
	struct timespec ts;

	ts.tv_sec = 0;
	ts.tv_nsec = (long)TWQ_REAPER_PERIOD_MSEC * 1000000L;
	(void)_nanosleep(&ts, NULL);
}

static uint16_t
twq_clamp_count(uint32_t value)
{

	if (value > UINT16_MAX)
		return (UINT16_MAX);
	return ((uint16_t)value);
}

static void
twq_plan_ready_locked(struct twq_runtime *rt, int lane, uint16_t admitted,
    uint16_t *wake_needed_out, uint16_t *spawn_needed_out)
{
	uint32_t grant, pending, same_lane_idle, transfer_idle, transfer_wake;
	uint32_t wake_needed, spawn_needed;

	same_lane_idle = 0;
	if (twq_lane_is_valid(lane))
		same_lane_idle = rt->tr_bucket[lane].tbr_idle;
	pending = rt->tr_bucket[lane].tbr_pending;
	grant = MIN((uint32_t)admitted, pending);

	wake_needed = 0;
	if (pending > grant) {
		wake_needed = MIN(same_lane_idle,
		    pending - grant);
	}

	transfer_idle = rt->tr_idle_workers;
	if (transfer_idle > wake_needed)
		transfer_idle -= wake_needed;
	else
		transfer_idle = 0;

	transfer_wake = MIN(transfer_idle, grant);
	wake_needed = MIN((uint32_t)UINT16_MAX, wake_needed + transfer_wake);
	spawn_needed = grant - transfer_wake;

	*wake_needed_out = (uint16_t)wake_needed;
	*spawn_needed_out = (uint16_t)spawn_needed;
}

static int
twq_bucket_from_sched_priority(uint32_t priority)
{

	if (priority <= 4)
		return (TWQ_BUCKET_MAINTENANCE);
	if (priority <= 8)
		return (TWQ_BUCKET_BACKGROUND);
	if (priority <= 20)
		return (TWQ_BUCKET_UTILITY);
	if (priority <= 31)
		return (TWQ_BUCKET_DEFAULT);
	if (priority <= 37)
		return (TWQ_BUCKET_USER_INITIATED);
	return (TWQ_BUCKET_USER_INTERACTIVE);
}

static qos_class_t
twq_qos_class_from_priority_token(uint32_t qos)
{
	int bit;

	switch (qos) {
	case TWQ_QOS_CLASS_MAINTENANCE:
		return (QOS_CLASS_MAINTENANCE);
	case TWQ_QOS_CLASS_BACKGROUND:
		return (QOS_CLASS_BACKGROUND);
	case TWQ_QOS_CLASS_UTILITY:
		return (QOS_CLASS_UTILITY);
	case TWQ_QOS_CLASS_DEFAULT:
	case TWQ_QOS_CLASS_UNSPECIFIED:
		return (QOS_CLASS_DEFAULT);
	case TWQ_QOS_CLASS_USER_INITIATED:
		return (QOS_CLASS_USER_INITIATED);
	case TWQ_QOS_CLASS_USER_INTERACTIVE:
		return (QOS_CLASS_USER_INTERACTIVE);
	default:
		break;
	}

	if (qos == 0 || (qos & (qos - 1U)) != 0)
		return (QOS_CLASS_DEFAULT);

	bit = ffs((int)qos);
	switch (bit) {
	case 1:
		return (QOS_CLASS_MAINTENANCE);
	case 2:
		return (QOS_CLASS_BACKGROUND);
	case 3:
		return (QOS_CLASS_UTILITY);
	case 4:
		return (QOS_CLASS_DEFAULT);
	case 5:
		return (QOS_CLASS_USER_INITIATED);
	case 6:
		return (QOS_CLASS_USER_INTERACTIVE);
	default:
		return (QOS_CLASS_DEFAULT);
	}
}

static uint32_t
twq_priority_token_from_qos_class(uint32_t qos_class)
{

	switch (qos_class) {
	case TWQ_QOS_CLASS_MAINTENANCE:
		return (1U << TWQ_BUCKET_MAINTENANCE);
	case TWQ_QOS_CLASS_BACKGROUND:
		return (1U << TWQ_BUCKET_BACKGROUND);
	case TWQ_QOS_CLASS_UTILITY:
		return (1U << TWQ_BUCKET_UTILITY);
	case TWQ_QOS_CLASS_USER_INITIATED:
		return (1U << TWQ_BUCKET_USER_INITIATED);
	case TWQ_QOS_CLASS_USER_INTERACTIVE:
		return (1U << TWQ_BUCKET_USER_INTERACTIVE);
	case TWQ_QOS_CLASS_DEFAULT:
	case TWQ_QOS_CLASS_UNSPECIFIED:
	default:
		return (1U << TWQ_BUCKET_DEFAULT);
	}
}

static int
twq_bucket_from_priority(pthread_priority_t priority)
{
	uint32_t qos;
	qos_class_t qos_class;

	if ((priority & TWQ_PRIORITY_SCHED_PRI_FLAG) != 0 &&
	    (priority & TWQ_PRIORITY_QOS_CLASS_MASK) == 0) {
		return (twq_bucket_from_sched_priority((uint32_t)(priority &
		    TWQ_PRIORITY_PRIORITY_MASK)));
	}

	qos = (uint32_t)((priority & TWQ_PRIORITY_QOS_CLASS_MASK) >>
	    TWQ_PRIORITY_QOS_CLASS_SHIFT);
	qos_class = twq_qos_class_from_priority_token(qos);
	switch (qos_class) {
	case QOS_CLASS_MAINTENANCE:
		return (TWQ_BUCKET_MAINTENANCE);
	case QOS_CLASS_BACKGROUND:
		return (TWQ_BUCKET_BACKGROUND);
	case QOS_CLASS_UTILITY:
		return (TWQ_BUCKET_UTILITY);
	case QOS_CLASS_DEFAULT:
	case QOS_CLASS_UNSPECIFIED:
		return (TWQ_BUCKET_DEFAULT);
	case QOS_CLASS_USER_INITIATED:
		return (TWQ_BUCKET_USER_INITIATED);
	case QOS_CLASS_USER_INTERACTIVE:
		return (TWQ_BUCKET_USER_INTERACTIVE);
	default:
		return (TWQ_BUCKET_DEFAULT);
	}
}

static int
twq_lane_from_priority(pthread_priority_t priority)
{
	int bucket;

	bucket = twq_bucket_from_priority(priority);
	return (twq_lane_make(bucket, twq_priority_is_overcommit(priority)));
}

static pthread_priority_t
twq_make_priority(uint32_t qos_class, uint32_t relpri, uint32_t flags)
{

	return ((((pthread_priority_t)twq_priority_token_from_qos_class(qos_class))
	    << TWQ_PRIORITY_QOS_CLASS_SHIFT) |
	    ((pthread_priority_t)relpri & TWQ_PRIORITY_PRIORITY_MASK) |
	    (pthread_priority_t)(flags & TWQ_PRIORITY_FLAGS_MASK));
}

static bool
twq_qos_class_valid(qos_class_t qos_class, int relative_priority)
{

	switch ((unsigned int)qos_class) {
	case QOS_CLASS_USER_INTERACTIVE:
	case QOS_CLASS_USER_INITIATED:
	case QOS_CLASS_DEFAULT:
	case QOS_CLASS_UTILITY:
	case QOS_CLASS_BACKGROUND:
	case QOS_CLASS_MAINTENANCE:
	case QOS_CLASS_UNSPECIFIED:
		break;
	default:
		return (false);
	}
	return (relative_priority >= QOS_MIN_RELATIVE_PRIORITY &&
	    relative_priority <= 0);
}

static pthread_priority_t
twq_priority_from_legacy(int queue_priority, int options, int *errorp)
{
	uint32_t flags, qos_class;

	flags = 0;
	if ((options & WORKQ_ADDTHREADS_OPTION_OVERCOMMIT) != 0)
		flags |= TWQ_PRIORITY_OVERCOMMIT_FLAG;

	switch (queue_priority) {
	case WORKQ_HIGH_PRIOQUEUE:
		qos_class = TWQ_QOS_CLASS_USER_INTERACTIVE;
		break;
	case WORKQ_DEFAULT_PRIOQUEUE:
		qos_class = TWQ_QOS_CLASS_DEFAULT;
		break;
	case WORKQ_NON_INTERACTIVE_PRIOQUEUE:
	case WORKQ_LOW_PRIOQUEUE:
		qos_class = TWQ_QOS_CLASS_UTILITY;
		break;
	case WORKQ_BG_PRIOQUEUE:
		qos_class = TWQ_QOS_CLASS_BACKGROUND;
		break;
	default:
		if (errorp != NULL)
			*errorp = EINVAL;
		return (0);
	}
	if (errorp != NULL)
		*errorp = 0;
	return (twq_make_priority(qos_class, 0, flags));
}

static int
twq_legacy_from_priority(pthread_priority_t priority)
{
	int bucket;

	bucket = twq_bucket_from_priority(priority);
	switch (bucket) {
	case TWQ_BUCKET_USER_INTERACTIVE:
	case TWQ_BUCKET_USER_INITIATED:
		return (WORKQ_HIGH_PRIOQUEUE);
	case TWQ_BUCKET_DEFAULT:
		return (WORKQ_DEFAULT_PRIOQUEUE);
	case TWQ_BUCKET_UTILITY:
		return (WORKQ_LOW_PRIOQUEUE);
	case TWQ_BUCKET_MAINTENANCE:
	case TWQ_BUCKET_BACKGROUND:
	default:
		return (WORKQ_BG_PRIOQUEUE);
	}
}

static int
twq_workqueue_options_from_priority(pthread_priority_t priority)
{

	if ((priority & TWQ_PRIORITY_OVERCOMMIT_FLAG) != 0)
		return (WORKQ_ADDTHREADS_OPTION_OVERCOMMIT);
	return (0);
}

static void
twq_runtime_init_locked(struct twq_runtime *rt)
{

	if (!rt->tr_supported_checked) {
		rt->tr_supported_features = twq_probe_supported_features();
		rt->tr_supported_checked = 1;
	}
	rt->tr_last_activity_msec = twq_now_msec();
}

static void *
twq_reaper_main(void *arg)
{
	struct twq_runtime *rt;
	struct pthread *curthread;
	pthread_priority_t redrive_priority;
	uint32_t retire_count, warm_floor;
	uint16_t admitted, desired, spawn_needed, wake_needed, woken_or_spawned;
	int error, redrive_lane;
	uint64_t now;
	bool redrive;

	rt = arg;
	curthread = _get_curthread();

	for (;;) {
		twq_reaper_pause();
		retire_count = 0;
		redrive = false;
		redrive_lane = -1;
		redrive_priority = 0;
		desired = 0;
		admitted = 0;
		spawn_needed = 0;
		wake_needed = 0;

		THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
		if (!rt->tr_initialized) {
			THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
			continue;
		}

		now = twq_now_msec();
		warm_floor = twq_warm_worker_floor();
		if (!twq_any_pending_locked(rt) &&
		    now - rt->tr_last_activity_msec >=
		    (uint64_t)TWQ_IDLE_TIMEOUT_SEC * 1000ULL &&
		    rt->tr_live_workers > warm_floor &&
		    rt->tr_idle_workers != 0) {
			retire_count = MIN(rt->tr_live_workers - warm_floor,
			    rt->tr_idle_workers);
			rt->tr_retire_budget += retire_count;
			rt->tr_wait_seq++;
			twq_trace_event_locked(rt, "reaper-retire", 0, 0, 0,
			    retire_count, retire_count, 0);
		}
		redrive_lane = twq_pick_redrive_lane_locked(rt);
		if (redrive_lane >= 0) {
			redrive_priority = rt->tr_bucket[redrive_lane].tbr_priority;
			desired = twq_lane_desired_locked(rt, redrive_lane);
			redrive = true;
			twq_trace_event_locked(rt, "reaper-redrive-begin",
			    redrive_lane, redrive_priority, desired, 0, 0, 0);
		}
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);

		if (retire_count != 0)
			_thr_umtx_wake(&rt->tr_wait_seq, (int)retire_count, 0);
		if (!redrive)
			continue;

		error = twq_kernel_sync_request(desired, redrive_priority);
		if (error < 0)
			continue;
		admitted = (uint16_t)MIN(error, UINT16_MAX);
		spawn_needed = admitted;

		THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
		if (!rt->tr_initialized ||
		    redrive_lane < 0 || redrive_lane >= TWQ_RUNTIME_NUM_LANES ||
		    rt->tr_bucket[redrive_lane].tbr_pending == 0 ||
		    rt->tr_bucket[redrive_lane].tbr_ready != 0) {
			THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
			continue;
		}
		twq_plan_ready_locked(rt, redrive_lane, admitted, &wake_needed,
		    &spawn_needed);
		woken_or_spawned = (uint16_t)MIN((uint32_t)UINT32_MAX,
		    (uint32_t)wake_needed + (uint32_t)spawn_needed);
		if (woken_or_spawned != 0) {
			rt->tr_bucket[redrive_lane].tbr_ready += woken_or_spawned;
			if (wake_needed != 0)
				rt->tr_wait_seq++;
		}
		twq_trace_event_locked(rt, "reaper-redrive-ready",
		    redrive_lane, redrive_priority, desired, admitted,
		    wake_needed, spawn_needed);
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);

		if (wake_needed != 0)
			_thr_umtx_wake(&rt->tr_wait_seq, (int)wake_needed, 0);
		if (spawn_needed != 0)
			(void)twq_spawn_workers(rt, spawn_needed);
	}
}

static int
twq_start_reaper(struct twq_runtime *rt)
{
	struct pthread_attr attr;
	pthread_attr_t attrp;
	pthread_t thread;

	attr = _pthread_attr_default;
	attr.flags |= PTHREAD_CREATE_DETACHED;
	attrp = &attr;
	return (_pthread_create(&thread, &attrp, twq_reaper_main, rt));
}

static uint16_t
twq_lane_desired_locked(struct twq_runtime *rt, int lane)
{
	uint32_t desired;

	desired = rt->tr_bucket[lane].tbr_pending +
	    rt->tr_bucket[lane].tbr_active;
	return (twq_clamp_count(desired));
}

static int
twq_sys_kernreturn(int op, void *arg2, int arg3, int arg4)
{
	long ret;

	ret = syscall(TWQ_SYS_KERNRETURN, op, arg2, arg3, arg4);
	return ((int)ret);
}

static int
twq_kernel_init(struct twq_runtime *rt)
{
	struct twq_init_args init_args;
	int ret;

	memset(&init_args, 0, sizeof(init_args));
	init_args.tqi_version = PTHREAD_WORKQUEUE_SPI_VERSION;
	init_args.tqi_requested_features = rt->tr_supported_features;
	init_args.tqi_stack_size = _pthread_attr_default.stacksize_attr;
	init_args.tqi_guard_size = _pthread_attr_default.guardsize_attr;

	ret = twq_sys_kernreturn(TWQ_OP_INIT, &init_args, sizeof(init_args), 0);
	if (ret == -1)
		return (errno);
	rt->tr_init_features = (uint32_t)ret;
	return (0);
}

static int
twq_kernel_setup_dispatch(uint64_t serialno_offs, uint64_t label_offs)
{
	struct twq_dispatch_config cfg;
	int ret;

	memset(&cfg, 0, sizeof(cfg));
	cfg.version = PTHREAD_WORKQUEUE_CONFIG_VERSION;
	cfg.queue_serialno_offs = serialno_offs;
	cfg.queue_label_offs = label_offs;

	ret = twq_sys_kernreturn(TWQ_OP_SETUP_DISPATCH, &cfg, sizeof(cfg), 0);
	if (ret == -1)
		return (errno);
	return (0);
}

static int
twq_kernel_sync_request(uint16_t desired, pthread_priority_t priority)
{
	struct twq_reqthreads_args req;
	int ret;

	priority = twq_priority_for_kernel(priority);
	memset(&req, 0, sizeof(req));
	req.tqr_version = TWQ_REQTHREADS_VERSION;
	req.tqr_reqcount = desired;
	req.tqr_priority = priority;

	ret = twq_sys_kernreturn(TWQ_OP_REQTHREADS, &req, sizeof(req), 0);
	if (ret == -1)
		return (-errno);
	return (ret);
}

static int
twq_kernel_thread_enter(pthread_priority_t priority)
{
	int ret;

	priority = twq_priority_for_kernel(priority);
	ret = twq_sys_kernreturn(TWQ_OP_THREAD_ENTER, NULL,
	    (int)((uint32_t)priority), 0);
	if (ret == -1)
		return (errno);
	return (0);
}

static int
twq_kernel_thread_return(pthread_priority_t priority)
{
	int ret;

	priority = twq_priority_for_kernel(priority);
	ret = twq_sys_kernreturn(TWQ_OP_THREAD_RETURN, NULL,
	    (int)((uint32_t)priority), 0);
	if (ret == -1)
		return (errno);
	return (0);
}

static int
twq_kernel_thread_transfer(uint16_t from_desired,
    pthread_priority_t from_priority, pthread_priority_t to_priority)
{
	struct twq_thread_transfer_args transfer;
	int ret;

	from_priority = twq_priority_for_kernel(from_priority);
	to_priority = twq_priority_for_kernel(to_priority);
	memset(&transfer, 0, sizeof(transfer));
	transfer.tqt_version = TWQ_THREAD_TRANSFER_VERSION;
	transfer.tqt_from_reqcount = from_desired;
	transfer.tqt_from_priority = from_priority;
	transfer.tqt_to_priority = to_priority;

	ret = twq_sys_kernreturn(TWQ_OP_THREAD_TRANSFER, &transfer,
	    sizeof(transfer), 0);
	if (ret == -1)
		return (errno);
	return (0);
}

static bool
twq_kernel_should_narrow(pthread_priority_t priority)
{
	int ret;

	priority = twq_priority_for_kernel(priority);
	ret = twq_sys_kernreturn(TWQ_OP_SHOULD_NARROW, NULL,
	    (int)((uint32_t)priority), 0);
	if (ret == -1)
		return (false);
	return (ret != 0);
}

static int
twq_pick_lane_locked(struct twq_runtime *rt, bool require_ready)
{
	int bucket, lane;

	for (bucket = TWQ_BUCKET_USER_INTERACTIVE;
	    bucket >= TWQ_BUCKET_MAINTENANCE; bucket--) {
		lane = twq_lane_make(bucket, true);
		if (rt->tr_bucket[lane].tbr_pending != 0 &&
		    (!require_ready || rt->tr_bucket[lane].tbr_ready != 0))
			return (lane);
		lane = twq_lane_make(bucket, false);
		if (rt->tr_bucket[lane].tbr_pending != 0 &&
		    (!require_ready || rt->tr_bucket[lane].tbr_ready != 0))
			return (lane);
	}
	return (-1);
}

static int
twq_pick_bucket_locked(struct twq_runtime *rt)
{
	return (twq_pick_lane_locked(rt, true));
}

static void
twq_invoke_callback(struct twq_runtime *rt, pthread_priority_t priority)
{

	if (rt->tr_worker_func != NULL) {
		rt->tr_worker_func(priority);
		return;
	}
	if (rt->tr_legacy_func != NULL) {
		rt->tr_legacy_func(twq_legacy_from_priority(priority),
		    twq_workqueue_options_from_priority(priority), NULL);
	}
}

static void *
twq_worker_main(void *arg)
{
	struct twq_runtime *rt;
	struct twq_worker *worker;
	struct pthread *curthread;
	pthread_priority_t handoff_priority;
	pthread_priority_t priority;
	pthread_priority_t return_priority;
	uint16_t handoff_desired;
	uint16_t desired;
	uint16_t return_desired;
	uint32_t warm_floor;
	int handoff_lane;
	int idle_lane;
	int lane;
	u_int wait_seq;
	bool handoff;
	bool same_lane_handoff;
	int error;
	int wait_error;

	worker = arg;
	rt = worker->tw_runtime;
	curthread = _get_curthread();
	warm_floor = twq_warm_worker_floor();
	idle_lane = -1;

	for (;;) {
		THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
		rt->tr_idle_workers++;
		if (twq_lane_is_valid(idle_lane))
			rt->tr_bucket[idle_lane].tbr_idle++;
		for (;;) {
			lane = twq_pick_bucket_locked(rt);
			if (lane >= 0)
				break;
			if (rt->tr_retire_budget != 0 &&
			    rt->tr_live_workers > warm_floor) {
				rt->tr_retire_budget--;
				if (rt->tr_idle_workers != 0)
					rt->tr_idle_workers--;
				if (twq_lane_is_valid(idle_lane) &&
				    rt->tr_bucket[idle_lane].tbr_idle != 0)
					rt->tr_bucket[idle_lane].tbr_idle--;
				if (rt->tr_live_workers != 0)
					rt->tr_live_workers--;
				twq_trace_event_locked(rt, "worker-retire",
				    -1, 0, 0, 0, 0, 0);
				THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
				goto out;
			}
			wait_seq = rt->tr_wait_seq;
			THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
			wait_error = _thr_umtx_wait_uint(&rt->tr_wait_seq,
			    wait_seq, NULL, 0);
			THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
			if (wait_error != 0)
				continue;
		}
		rt->tr_idle_workers--;
		if (twq_lane_is_valid(idle_lane) &&
		    rt->tr_bucket[idle_lane].tbr_idle != 0)
			rt->tr_bucket[idle_lane].tbr_idle--;
		idle_lane = -1;
		rt->tr_bucket[lane].tbr_pending--;
		if (rt->tr_bucket[lane].tbr_ready != 0)
			rt->tr_bucket[lane].tbr_ready--;
		rt->tr_bucket[lane].tbr_active++;
		twq_note_activity_locked(rt);
		priority = rt->tr_bucket[lane].tbr_priority;
		desired = twq_lane_desired_locked(rt, lane);
		twq_trace_event_locked(rt, "worker-claim", lane, priority,
		    desired, 0, 0, 0);
	run_activation:
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
		/*
		 * Claiming a ready unit moves one lane slot from pending to active,
		 * so the aggregate desired count for this lane does not change.
		 * The request side already synchronized that desired count before
		 * waking or spawning this worker; only the enter transition needs
		 * to reach the kernel here.
		 */
		error = twq_kernel_thread_enter(priority);
	run_callback:
		if (error == 0)
			twq_invoke_callback(rt, priority);

		THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
		if (rt->tr_bucket[lane].tbr_active != 0)
			rt->tr_bucket[lane].tbr_active--;
		twq_note_activity_locked(rt);
		return_priority = priority;
		return_desired = twq_lane_desired_locked(rt, lane);
		twq_trace_event_locked(rt, "worker-return", lane, priority,
		    return_desired, 0, 0, 0);
		handoff = false;
		same_lane_handoff = false;
		/*
		 * libdispatch accounts one callback per admitted worker.  A
		 * pending request without a ready slot still belongs to the
		 * reaper/spawn path, not direct handoff by this returning worker.
		 */
		handoff_lane = twq_pick_bucket_locked(rt);
		if (handoff_lane >= 0) {
			rt->tr_bucket[handoff_lane].tbr_pending--;
			if (rt->tr_bucket[handoff_lane].tbr_ready != 0)
				rt->tr_bucket[handoff_lane].tbr_ready--;
			rt->tr_bucket[handoff_lane].tbr_active++;
			handoff_priority = rt->tr_bucket[handoff_lane].tbr_priority;
			handoff_desired = twq_lane_desired_locked(rt, handoff_lane);
			handoff = true;
			same_lane_handoff = (handoff_lane == lane);
			twq_trace_event_locked(rt, "worker-handoff-claim",
			    handoff_lane, handoff_priority, handoff_desired, 0, 0, 0);
		}
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);

		if (same_lane_handoff) {
			/*
			 * A direct handoff on the same lane keeps this worker
			 * continuously active in the same kernel bucket. Avoid a
			 * redundant REQTHREADS/THREAD_RETURN/THREAD_ENTER cycle
			 * and continue straight into the next callback.
			 */
			lane = handoff_lane;
			priority = handoff_priority;
			desired = handoff_desired;
			twq_trace_event(rt, "worker-handoff-fastpath", lane,
			    priority, desired, 0, 0, 0);
			error = 0;
			goto run_callback;
		}

		if (!handoff) {
			(void)twq_kernel_sync_request(return_desired,
			    return_priority);
			(void)twq_kernel_thread_return(return_priority);
			idle_lane = lane;
			continue;
		}

		lane = handoff_lane;
		priority = handoff_priority;
		desired = handoff_desired;
		error = twq_kernel_thread_transfer(return_desired, return_priority,
		    handoff_priority);
		if (error == 0) {
			twq_trace_event(rt, "worker-handoff-transfer", lane,
			    priority, desired, 0, 0, 0);
			goto run_callback;
		}
		(void)twq_kernel_sync_request(return_desired, return_priority);
		(void)twq_kernel_thread_return(return_priority);
		twq_trace_event(rt, "worker-handoff-enter", lane, priority,
		    desired, 0, 0, 0);
		THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
		goto run_activation;
	}

out:
	free(worker);
	return (NULL);
}

static int
twq_spawn_workers(struct twq_runtime *rt, uint16_t count)
{
	struct pthread_attr attr;
	pthread_attr_t attrp;
	pthread_t thread;
	struct twq_worker *worker;
	struct pthread *curthread;
	int error;
	uint16_t i;

	attr = _pthread_attr_default;
	attr.flags |= PTHREAD_CREATE_DETACHED;
	attrp = &attr;
	curthread = _get_curthread();

	for (i = 0; i < count; i++) {
		worker = calloc(1, sizeof(*worker));
		if (worker == NULL)
			return (EAGAIN);
		worker->tw_runtime = rt;
		error = _pthread_create(&thread, &attrp, twq_worker_main, worker);
		if (error != 0) {
			free(worker);
			return (error);
		}
		THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
		rt->tr_live_workers++;
		twq_trace_event_locked(rt, "spawned", -1, 0, i + 1,
			    count, 0, 0);
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
	}
	return (0);
}

static int
twq_configure_runtime(pthread_workqueue_function2_t worker_func,
    pthread_workqueue_function_t legacy_func, uint64_t serialno_offs,
    uint64_t label_offs)
{
	struct twq_runtime *rt;
	struct pthread *curthread;
	int error;

	rt = &twq_runtime;
	_thr_check_init();
	curthread = _get_curthread();
	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	twq_runtime_init_locked(rt);
	if (rt->tr_configuring || rt->tr_initialized) {
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
		return (EBUSY);
	}
	rt->tr_configuring = 1;
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);

	error = twq_kernel_init(rt);
	if (error == 0)
		error = twq_kernel_setup_dispatch(serialno_offs, label_offs);
	if (error == 0 && !rt->tr_reaper_started) {
		error = twq_start_reaper(rt);
		if (error == 0)
			rt->tr_reaper_started = 1;
	}

	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	rt->tr_configuring = 0;
	if (error == 0) {
		rt->tr_initialized = 1;
		rt->tr_worker_func = worker_func;
		rt->tr_legacy_func = legacy_func;
		rt->tr_queue_serialno_offs = serialno_offs;
		rt->tr_queue_label_offs = label_offs;
	}
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
	return (error);
}

static int
twq_addthreads_common(uint32_t numthreads, pthread_priority_t priority)
{
	struct twq_runtime *rt;
	struct pthread *curthread;
	uint16_t admitted, desired, spawn_needed, wake_needed, woken_or_spawned;
	int lane;
	int error;

	if ((int)numthreads < 0)
		return (EINVAL);

	_thr_check_init();
	curthread = _get_curthread();
	rt = &twq_runtime;
	lane = twq_lane_from_priority(priority);

	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	if (!rt->tr_initialized ||
	    (rt->tr_worker_func == NULL && rt->tr_legacy_func == NULL)) {
		THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
		return (EPERM);
	}
	rt->tr_bucket[lane].tbr_pending = MIN(UINT32_MAX - numthreads,
	    rt->tr_bucket[lane].tbr_pending) + numthreads;
	rt->tr_bucket[lane].tbr_priority = priority;
	twq_note_activity_locked(rt);
	desired = twq_lane_desired_locked(rt, lane);
	twq_trace_event_locked(rt, "addthreads-begin", lane, priority,
	    numthreads, 0, 0, 0);
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);

	error = twq_kernel_sync_request(desired, priority);
	if (error < 0)
		return (-error);
	admitted = (uint16_t)MIN(error, UINT16_MAX);

	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	twq_plan_ready_locked(rt, lane, admitted, &wake_needed, &spawn_needed);
	woken_or_spawned = (uint16_t)MIN((uint32_t)UINT32_MAX,
	    (uint32_t)wake_needed + (uint32_t)spawn_needed);
	if (woken_or_spawned != 0) {
		rt->tr_bucket[lane].tbr_ready += woken_or_spawned;
		if (wake_needed != 0)
			rt->tr_wait_seq++;
	}
	twq_trace_event_locked(rt, "addthreads-ready", lane, priority,
	    numthreads, admitted, wake_needed, spawn_needed);
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
	if (wake_needed != 0)
		_thr_umtx_wake(&rt->tr_wait_seq, (int)wake_needed, 0);

	if (spawn_needed != 0) {
		error = twq_spawn_workers(rt, spawn_needed);
		if (error != 0) {
			THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
			if (rt->tr_bucket[lane].tbr_ready >= spawn_needed)
				rt->tr_bucket[lane].tbr_ready -= spawn_needed;
			else
				rt->tr_bucket[lane].tbr_ready = 0;
			THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
			return (error);
		}
	}
	return (0);
}

int
pthread_workqueue_setup(struct pthread_workqueue_config *cfg, size_t cfg_size)
{
	size_t min_size;

	if (cfg == NULL || cfg_size < sizeof(uint32_t))
		return (EINVAL);

	switch (cfg->version) {
	case 1:
		min_size = offsetof(struct pthread_workqueue_config,
		    queue_label_offs);
		break;
	case 2:
		min_size = sizeof(*cfg);
		break;
	default:
		return (EINVAL);
	}
	if (cfg_size < min_size)
		return (EINVAL);
	if ((cfg->flags & ~PTHREAD_WORKQUEUE_CONFIG_SUPPORTED_FLAGS) != 0)
		return (ENOTSUP);
	if (cfg->version < PTHREAD_WORKQUEUE_CONFIG_MIN_SUPPORTED_VERSION)
		return (ENOTSUP);
	if (cfg->kevent_cb != NULL || cfg->workloop_cb != NULL)
		return (ENOTSUP);
	if (cfg->workq_cb == NULL)
		return (EINVAL);

	return (twq_configure_runtime(cfg->workq_cb, NULL,
	    cfg->queue_serialno_offs, cfg->queue_label_offs));
}

int
_pthread_workqueue_init_with_workloop(pthread_workqueue_function2_t queue_func,
    pthread_workqueue_function_kevent_t kevent_func,
    pthread_workqueue_function_workloop_t workloop_func, int offset, int flags)
{

	if (flags != 0)
		return (ENOTSUP);
	if (kevent_func != NULL || workloop_func != NULL)
		return (ENOTSUP);
	return (twq_configure_runtime(queue_func, NULL, (uint64_t)offset, 0));
}

int
_pthread_workqueue_init_with_kevent(pthread_workqueue_function2_t queue_func,
    pthread_workqueue_function_kevent_t kevent_func, int offset, int flags)
{

	return (_pthread_workqueue_init_with_workloop(queue_func, kevent_func,
	    NULL, offset, flags));
}

int
_pthread_workqueue_init(pthread_workqueue_function2_t func, int offset, int flags)
{

	return (_pthread_workqueue_init_with_kevent(func, NULL, offset, flags));
}

int
__pthread_workqueue_setkill(int enable __unused)
{

	return (0);
}

int
pthread_workqueue_setdispatch_np(pthread_workqueue_function_t worker_func)
{

	if (worker_func == NULL)
		return (EINVAL);
	return (twq_configure_runtime(NULL, worker_func,
	    (uint64_t)twq_runtime.tr_dispatch_offset, 0));
}

void
pthread_workqueue_setdispatchoffset_np(int offset)
{
	struct twq_runtime *rt;
	struct pthread *curthread;

	_thr_check_init();
	rt = &twq_runtime;
	curthread = _get_curthread();
	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	twq_runtime_init_locked(rt);
	if (!rt->tr_initialized)
		rt->tr_dispatch_offset = offset;
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
}

int
pthread_workqueue_addthreads_np(int queue_priority, int options, int numthreads)
{
	pthread_priority_t priority;
	int error;

	priority = twq_priority_from_legacy(queue_priority, options, &error);
	if (error != 0)
		return (error);
	return (twq_addthreads_common((uint32_t)numthreads, priority));
}

int
_pthread_workqueue_supported(void)
{
	struct twq_runtime *rt;
	struct pthread *curthread;
	int features;

	_thr_check_init();
	rt = &twq_runtime;
	curthread = _get_curthread();
	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	twq_runtime_init_locked(rt);
	features = rt->tr_init_features != 0 ? (int)rt->tr_init_features :
	    rt->tr_supported_features;
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
	return (features);
}

int
_pthread_workqueue_addthreads(int numthreads, pthread_priority_t priority)
{

	return (twq_addthreads_common((uint32_t)numthreads, priority));
}

bool
_pthread_workqueue_should_narrow(pthread_priority_t priority)
{
	struct twq_runtime *rt;
	struct pthread *curthread;
	bool should_narrow;

	should_narrow = twq_kernel_should_narrow(priority);
	if (!should_narrow)
		return (false);
	if ((priority & TWQ_PRIORITY_OVERCOMMIT_FLAG) != 0)
		return (true);

	rt = &twq_runtime;
	curthread = _get_curthread();
	THR_UMUTEX_LOCK(curthread, &rt->tr_lock);
	should_narrow = rt->tr_live_workers > twq_warm_worker_floor();
	THR_UMUTEX_UNLOCK(curthread, &rt->tr_lock);
	return (should_narrow);
}

int
_pthread_workqueue_set_event_manager_priority(pthread_priority_t priority __unused)
{

	return (ENOTSUP);
}

pthread_priority_t
_pthread_qos_class_encode(qos_class_t qos_class, int relative_priority,
    unsigned long flags)
{

	if (!twq_qos_class_valid(qos_class, relative_priority))
		return (0);
	return (twq_make_priority((uint32_t)qos_class,
	    (uint32_t)(uint8_t)relative_priority, (uint32_t)flags));
}

qos_class_t
_pthread_qos_class_decode(pthread_priority_t priority, int *relative_priority,
    unsigned long *flags)
{
	qos_class_t qos_class;
	uint32_t qos;

	qos = (uint32_t)((priority & TWQ_PRIORITY_QOS_CLASS_MASK) >>
	    TWQ_PRIORITY_QOS_CLASS_SHIFT);
	qos_class = twq_qos_class_from_priority_token(qos);
	if (relative_priority != NULL)
		*relative_priority = (int)((int8_t)(priority &
		    TWQ_PRIORITY_PRIORITY_MASK));
	if (flags != NULL)
		*flags = (unsigned long)(priority & TWQ_PRIORITY_FLAGS_MASK);
	return (qos_class);
}

pthread_priority_t
_pthread_qos_class_encode_workqueue(int queue_priority, unsigned long flags)
{
	int error;

	return (twq_priority_from_legacy(queue_priority, (int)flags, &error));
}

qos_class_t
qos_class_self(void)
{

	return (QOS_CLASS_DEFAULT);
}

qos_class_t
qos_class_main(void)
{

	return (QOS_CLASS_DEFAULT);
}

int
pthread_set_qos_class_self_np(qos_class_t qos_class, int relative_priority)
{

	if (!twq_qos_class_valid(qos_class, relative_priority))
		return (EINVAL);
	return (0);
}

int
_pthread_set_properties_self(_pthread_set_flags_t flags __unused,
    pthread_priority_t priority __unused, uint32_t voucher __unused)
{

	return (0);
}

int
pthread_qos_max_parallelism(qos_class_t qos __unused, unsigned long flags)
{
	long cpus;

	if ((flags & ~PTHREAD_MAX_PARALLELISM_PHYSICAL) != 0) {
		errno = EINVAL;
		return (-1);
	}
	cpus = sysconf(_SC_NPROCESSORS_ONLN);
	if (cpus < 1)
		cpus = 1;
	return ((int)cpus);
}

int
pthread_time_constraint_max_parallelism(unsigned long flags)
{

	return (pthread_qos_max_parallelism(QOS_CLASS_UNSPECIFIED, flags));
}

int
_pthread_qos_override_start_direct(uint32_t thread __unused,
    pthread_priority_t priority __unused, void *resource __unused)
{

	return (0);
}

int
_pthread_qos_override_end_direct(uint32_t thread __unused,
    void *resource __unused)
{

	return (0);
}

int
_pthread_override_qos_class_start_direct(uint32_t thread,
    pthread_priority_t priority)
{

	return (_pthread_qos_override_start_direct(thread, priority, NULL));
}

int
_pthread_override_qos_class_end_direct(uint32_t thread)
{

	return (_pthread_qos_override_end_direct(thread, NULL));
}

int
_pthread_workqueue_override_start_direct(uint32_t thread __unused,
    pthread_priority_t priority __unused)
{

	return (0);
}

int
_pthread_workqueue_override_start_direct_check_owner(uint32_t thread,
    pthread_priority_t priority, uint32_t *ulock_addr __unused)
{

	return (_pthread_workqueue_override_start_direct(thread, priority));
}

int
_pthread_workqueue_override_reset(void)
{

	return (0);
}
