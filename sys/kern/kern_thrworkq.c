#include "opt_thrworkq.h"

#include <sys/param.h>
#include <sys/errno.h>
#include <sys/eventhandler.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/mutex.h>
#include <sys/proc.h>
#include <sys/smp.h>
#include <sys/systm.h>
#include <sys/sysctl.h>
#include <sys/sysproto.h>
#include <sys/thrworkq.h>

#define	TWQP_CONFIGURED		0x0001
#define	TWQP_DISPATCH_SETUP	0x0002

#define	TWQT_COUNTED		0x01
#define	TWQT_IDLE		0x02
#define	TWQT_SWITCH_TRACKED	0x04
#define	TWQT_ACTIVE		0x08
#define	TWQ_NUM_LANES		(TWQ_NUM_BUCKETS * 2)

TAILQ_HEAD(twq_thread_head, twq_thread);

struct twq_proc {
	struct mtx		tqp_lock;
	struct proc		*tqp_proc;
	uint32_t		tqp_flags;
	uint32_t		tqp_features;
	uint32_t		tqp_spi_version;
	uint32_t		tqp_dispatch_version;
	uint32_t		tqp_dispatch_flags;
	uintptr_t		tqp_dispatch_func;
	size_t			tqp_stack_size;
	size_t			tqp_guard_size;
	uint64_t		tqp_queue_serialno_offs;
	uint64_t		tqp_queue_label_offs;
	uint16_t		tqp_req_count[TWQ_NUM_LANES];
	uint16_t		tqp_scheduled_count[TWQ_NUM_LANES];
	uint16_t		tqp_total_count[TWQ_NUM_LANES];
	uint16_t		tqp_idle_count[TWQ_NUM_LANES];
	uint32_t		tqp_active_count[TWQ_NUM_LANES];
	uint64_t		tqp_lastblocked_ts[TWQ_NUM_LANES];
	struct twq_thread_head	tqp_running;
	struct twq_thread_head	tqp_idle;
};

struct twq_thread {
	struct thread		*tqt_td;
	struct twq_proc		*tqt_proc;
	uint8_t			tqt_lane;
	uint8_t			tqt_flags;
	TAILQ_ENTRY(twq_thread) tqt_entry;
};

MALLOC_DEFINE(M_TWQ, "twq", "pthread_workqueue state");
SYSCTL_NODE(_kern, OID_AUTO, twq, CTLFLAG_RD | CTLFLAG_MPSAFE, 0,
    "pthread_workqueue state");

static long twq_proc_alloc_count;
static long twq_proc_free_count;
static long twq_thread_state_alloc_count;
static long twq_thread_state_free_count;
static long twq_init_count;
static long twq_thread_enter_count;
static long twq_setup_dispatch_count;
static long twq_reqthreads_count;
static long twq_thread_return_count;
static long twq_thread_transfer_count;
static long twq_should_narrow_count;
static long twq_should_narrow_true_count;
static long twq_switch_block_count;
static long twq_switch_unblock_count;
static long twq_bucket_thread_enter_total[TWQ_NUM_BUCKETS];
static long twq_bucket_req_total[TWQ_NUM_BUCKETS];
static long twq_bucket_admit_total[TWQ_NUM_BUCKETS];
static long twq_bucket_thread_return_total[TWQ_NUM_BUCKETS];
static long twq_bucket_switch_block_total[TWQ_NUM_BUCKETS];
static long twq_bucket_switch_unblock_total[TWQ_NUM_BUCKETS];
static long twq_bucket_total_current[TWQ_NUM_BUCKETS];
static long twq_bucket_idle_current[TWQ_NUM_BUCKETS];
static long twq_bucket_active_current[TWQ_NUM_BUCKETS];
static int twq_busy_window_usecs = 200;

SYSCTL_LONG(_kern_twq, OID_AUTO, proc_alloc_count, CTLFLAG_RD,
    &twq_proc_alloc_count, 0, "twq proc state allocations");
SYSCTL_LONG(_kern_twq, OID_AUTO, proc_free_count, CTLFLAG_RD,
    &twq_proc_free_count, 0, "twq proc state frees");
SYSCTL_LONG(_kern_twq, OID_AUTO, thread_state_alloc_count, CTLFLAG_RD,
    &twq_thread_state_alloc_count, 0, "twq thread state allocations");
SYSCTL_LONG(_kern_twq, OID_AUTO, thread_state_free_count, CTLFLAG_RD,
    &twq_thread_state_free_count, 0, "twq thread state frees");
SYSCTL_LONG(_kern_twq, OID_AUTO, init_count, CTLFLAG_RD,
    &twq_init_count, 0, "successful TWQ_OP_INIT calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, thread_enter_count, CTLFLAG_RD,
    &twq_thread_enter_count, 0, "successful TWQ_OP_THREAD_ENTER calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, setup_dispatch_count, CTLFLAG_RD,
    &twq_setup_dispatch_count, 0, "successful TWQ_OP_SETUP_DISPATCH calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, reqthreads_count, CTLFLAG_RD,
    &twq_reqthreads_count, 0, "successful TWQ_OP_REQTHREADS calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, thread_return_count, CTLFLAG_RD,
    &twq_thread_return_count, 0, "successful TWQ_OP_THREAD_RETURN calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, thread_transfer_count, CTLFLAG_RD,
    &twq_thread_transfer_count, 0,
    "successful TWQ_OP_THREAD_TRANSFER calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, should_narrow_count, CTLFLAG_RD,
    &twq_should_narrow_count, 0, "successful TWQ_OP_SHOULD_NARROW calls");
SYSCTL_LONG(_kern_twq, OID_AUTO, should_narrow_true_count, CTLFLAG_RD,
    &twq_should_narrow_true_count, 0,
    "TWQ_OP_SHOULD_NARROW calls that returned true");
SYSCTL_LONG(_kern_twq, OID_AUTO, switch_block_count, CTLFLAG_RD,
    &twq_switch_block_count, 0, "tracked blocking switches for twq threads");
SYSCTL_LONG(_kern_twq, OID_AUTO, switch_unblock_count, CTLFLAG_RD,
    &twq_switch_unblock_count, 0,
    "tracked unblock switches for twq threads");
SYSCTL_INT(_kern_twq, OID_AUTO, busy_window_usecs, CTLFLAG_RWTUN,
    &twq_busy_window_usecs, 0,
    "microseconds a recent blocked worker counts as busy for admission");

static int
sysctl_twq_bucket_array(SYSCTL_HANDLER_ARGS)
{
	long *stats;
	char buf[192];
	int len;

	stats = arg1;
	len = snprintf(buf, sizeof(buf), "%ld,%ld,%ld,%ld,%ld,%ld",
	    stats[TWQ_BUCKET_MAINTENANCE], stats[TWQ_BUCKET_BACKGROUND],
	    stats[TWQ_BUCKET_UTILITY], stats[TWQ_BUCKET_DEFAULT],
	    stats[TWQ_BUCKET_USER_INITIATED],
	    stats[TWQ_BUCKET_USER_INTERACTIVE]);
	return (SYSCTL_OUT(req, buf, len + 1));
}

SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_req_total,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE, twq_bucket_req_total, 0,
    sysctl_twq_bucket_array, "A",
    "cumulative requested worker count by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_thread_enter_total,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_thread_enter_total, 0, sysctl_twq_bucket_array, "A",
    "cumulative TWQ_OP_THREAD_ENTER count by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_admit_total,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE, twq_bucket_admit_total, 0,
    sysctl_twq_bucket_array, "A",
    "cumulative admitted worker count by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_thread_return_total,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_thread_return_total, 0, sysctl_twq_bucket_array, "A",
    "cumulative TWQ_OP_THREAD_RETURN count by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_switch_block_total,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_switch_block_total, 0, sysctl_twq_bucket_array, "A",
    "cumulative tracked blocking switches by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_switch_unblock_total,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_switch_unblock_total, 0, sysctl_twq_bucket_array, "A",
    "cumulative tracked unblock switches by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_total_current,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_total_current, 0, sysctl_twq_bucket_array, "A",
    "current counted worker threads by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_idle_current,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_idle_current, 0, sysctl_twq_bucket_array, "A",
    "current idle worker threads by bucket");
SYSCTL_PROC(_kern_twq, OID_AUTO, bucket_active_current,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE,
    twq_bucket_active_current, 0, sysctl_twq_bucket_array, "A",
    "current active worker threads by bucket");

static void
twq_stats_add(long *counter, long delta)
{

	atomic_add_long(counter, delta);
}

static void
twq_stats_inc(long *counter)
{

	twq_stats_add(counter, 1);
}

static void
twq_stats_add_bucket(long stats[TWQ_NUM_BUCKETS], int bucket, long delta)
{

	if (bucket < 0 || bucket >= TWQ_NUM_BUCKETS)
		return;
	twq_stats_add(&stats[bucket], delta);
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

	return (lane >= 0 && lane < TWQ_NUM_LANES);
}

static void
twq_lane_total_adjust_locked(struct twq_proc *tqp, int lane, int delta)
{

	if (delta == 0)
		return;
	tqp->tqp_total_count[lane] =
	    (uint16_t)((int)tqp->tqp_total_count[lane] + delta);
	twq_stats_add_bucket(twq_bucket_total_current, twq_lane_bucket(lane),
	    delta);
}

static void
twq_lane_idle_adjust_locked(struct twq_proc *tqp, int lane, int delta)
{

	if (delta == 0)
		return;
	tqp->tqp_idle_count[lane] =
	    (uint16_t)((int)tqp->tqp_idle_count[lane] + delta);
	twq_stats_add_bucket(twq_bucket_idle_current, twq_lane_bucket(lane),
	    delta);
}

static void
twq_lane_active_adjust(struct twq_proc *tqp, int lane, int delta)
{

	if (delta == 0)
		return;
	atomic_add_int((volatile u_int *)&tqp->tqp_active_count[lane], delta);
	twq_stats_add_bucket(twq_bucket_active_current, twq_lane_bucket(lane),
	    delta);
}

static uint64_t
twq_now_usec(void)
{
	struct timeval tv;

	microuptime(&tv);
	return ((uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec);
}

static bool
twq_switch_tracks_block(int flags)
{

	switch (flags & SW_TYPE_MASK) {
	case SWT_SLEEPQ:
	case SWT_TURNSTILE:
	case SWT_IWAIT:
	case SWT_SUSPEND:
		return (true);
	default:
		return (false);
	}
}

static uint16_t
twq_parallelism_limit(twq_priority_t priority)
{
	u_int limit;

	limit = MAX(1, mp_ncpus);
	if ((priority & TWQ_PRIORITY_OVERCOMMIT_FLAG) != 0)
		limit = MIN(limit * 2U, (u_int)UINT16_MAX);
	return ((uint16_t)limit);
}

static bool
twq_lane_recently_blocked(struct twq_proc *tqp, int lane, uint64_t now)
{
	uint64_t lastblocked;

	lastblocked = atomic_load_64(
	    (volatile uint64_t *)&tqp->tqp_lastblocked_ts[lane]);
	if (lastblocked == 0)
		return (false);
	if (lastblocked >= now)
		return (true);
	return (now - lastblocked <= (uint64_t)MAX(twq_busy_window_usecs, 0));
}

static uint16_t
twq_lane_effective_occupancy_locked(struct twq_proc *tqp, int lane,
    uint64_t now)
{
	uint16_t active, nonidle;

	active = MIN((uint16_t)atomic_load_int(
	    (volatile u_int *)&tqp->tqp_active_count[lane]), UINT16_MAX);
	nonidle = tqp->tqp_total_count[lane];
	if (nonidle > tqp->tqp_idle_count[lane])
		nonidle -= tqp->tqp_idle_count[lane];
	else
		nonidle = 0;
	if (nonidle > active &&
	    twq_lane_recently_blocked(tqp, lane, now))
		active = MIN((uint16_t)(active + 1), UINT16_MAX);
	return (active);
}

static uint16_t
twq_bucket_effective_occupancy_locked(struct twq_proc *tqp, int bucket,
    uint64_t now)
{
	uint16_t occupancy;

	occupancy = twq_lane_effective_occupancy_locked(tqp,
	    twq_lane_make(bucket, false), now);
	occupancy = MIN((uint16_t)(occupancy +
	    twq_lane_effective_occupancy_locked(tqp,
	    twq_lane_make(bucket, true), now)), UINT16_MAX);
	return (occupancy);
}

static uint16_t
twq_higher_bucket_pressure_locked(struct twq_proc *tqp, int bucket,
    uint64_t now)
{
	uint16_t pressure;
	int i;

	pressure = 0;
	for (i = bucket + 1; i < TWQ_NUM_BUCKETS; i++) {
		pressure = MIN((uint16_t)(pressure +
		    twq_bucket_effective_occupancy_locked(tqp, i, now)),
		    UINT16_MAX);
	}
	return (pressure);
}

static uint16_t
twq_lane_target_locked(struct twq_proc *tqp, int lane, twq_priority_t priority)
{
	uint16_t higher_pressure, limit, requested;
	int bucket;
	uint64_t now;

	now = twq_now_usec();
	bucket = twq_lane_bucket(lane);
	requested = tqp->tqp_req_count[lane];
	limit = twq_parallelism_limit(priority);
	higher_pressure = twq_higher_bucket_pressure_locked(tqp, bucket, now);
	if (higher_pressure >= limit)
		return (0);
	return (MIN(requested, limit - higher_pressure));
}

static bool
twq_known_op(int op)
{

	switch (op) {
	case TWQ_OP_INIT:
	case TWQ_OP_THREAD_ENTER:
	case TWQ_OP_THREAD_RETURN:
	case TWQ_OP_THREAD_TRANSFER:
	case TWQ_OP_REQTHREADS:
	case TWQ_OP_REQTHREADS2:
	case TWQ_OP_SHOULD_NARROW:
	case TWQ_OP_SETUP_DISPATCH:
		return (true);
	default:
		return (false);
	}
}

static uint32_t
twq_supported_features(void)
{

	return (TWQ_FEATURE_DISPATCHFUNC | TWQ_FEATURE_FINEPRIO |
	    TWQ_FEATURE_MAINTENANCE);
}

static uint16_t
twq_clamp_count(uint32_t value)
{

	if (value > UINT16_MAX)
		return (UINT16_MAX);
	return ((uint16_t)value);
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

static int
twq_bucket_from_qos_token(uint32_t qos)
{
	int bit;

	switch (qos) {
	case TWQ_QOS_CLASS_MAINTENANCE:
		return (TWQ_BUCKET_MAINTENANCE);
	case TWQ_QOS_CLASS_BACKGROUND:
		return (TWQ_BUCKET_BACKGROUND);
	case TWQ_QOS_CLASS_UTILITY:
		return (TWQ_BUCKET_UTILITY);
	case TWQ_QOS_CLASS_DEFAULT:
	case TWQ_QOS_CLASS_UNSPECIFIED:
		return (TWQ_BUCKET_DEFAULT);
	case TWQ_QOS_CLASS_USER_INITIATED:
		return (TWQ_BUCKET_USER_INITIATED);
	case TWQ_QOS_CLASS_USER_INTERACTIVE:
		return (TWQ_BUCKET_USER_INTERACTIVE);
	default:
		break;
	}

	if (qos == 0 || (qos & (qos - 1U)) != 0)
		return (TWQ_BUCKET_DEFAULT);

	bit = ffs((int)qos);
	switch (bit) {
	case 1:
		return (TWQ_BUCKET_MAINTENANCE);
	case 2:
		return (TWQ_BUCKET_BACKGROUND);
	case 3:
		return (TWQ_BUCKET_UTILITY);
	case 4:
		return (TWQ_BUCKET_DEFAULT);
	case 5:
		return (TWQ_BUCKET_USER_INITIATED);
	case 6:
		return (TWQ_BUCKET_USER_INTERACTIVE);
	default:
		return (TWQ_BUCKET_DEFAULT);
	}
}

static int
twq_bucket_from_priority(twq_priority_t priority)
{
	uint32_t qos;

	if ((priority & TWQ_PRIORITY_SCHED_PRI_FLAG) != 0)
		return (twq_bucket_from_sched_priority(priority &
		    TWQ_PRIORITY_PRIORITY_MASK));

	qos = (uint32_t)((priority & TWQ_PRIORITY_QOS_CLASS_MASK) >>
	    TWQ_PRIORITY_QOS_CLASS_SHIFT);
	return (twq_bucket_from_qos_token(qos));
}

static int
twq_lane_from_priority(twq_priority_t priority)
{

	return (twq_lane_make(twq_bucket_from_priority(priority),
	    (priority & TWQ_PRIORITY_OVERCOMMIT_FLAG) != 0));
}

static struct twq_proc *
twq_proc_alloc(struct proc *p)
{
	struct twq_proc *tqp;

	tqp = malloc(sizeof(*tqp), M_TWQ, M_WAITOK | M_ZERO);
	mtx_init(&tqp->tqp_lock, "twq proc", NULL, MTX_DEF);
	tqp->tqp_proc = p;
	TAILQ_INIT(&tqp->tqp_running);
	TAILQ_INIT(&tqp->tqp_idle);
	twq_stats_inc(&twq_proc_alloc_count);
	return (tqp);
}

static void
twq_proc_free(struct twq_proc *tqp)
{

	twq_stats_inc(&twq_proc_free_count);
	mtx_destroy(&tqp->tqp_lock);
	free(tqp, M_TWQ);
}

static struct twq_proc *
twq_proc_get(struct proc *p)
{
	struct twq_proc *new_tqp, *tqp;

	tqp = p->p_twq;
	if (tqp != NULL)
		return (tqp);

	new_tqp = twq_proc_alloc(p);
	PROC_LOCK(p);
	if (p->p_twq == NULL) {
		p->p_twq = new_tqp;
		new_tqp = NULL;
	}
	tqp = p->p_twq;
	PROC_UNLOCK(p);

	if (new_tqp != NULL)
		twq_proc_free(new_tqp);
	return (tqp);
}

static void
twq_thread_dispose_locked(struct twq_thread *tqt)
{
	struct twq_proc *tqp;
	int lane;

	tqp = tqt->tqt_proc;
	if (tqp == NULL)
		return;

	lane = tqt->tqt_lane;
	if ((tqt->tqt_flags & TWQT_IDLE) != 0) {
		TAILQ_REMOVE(&tqp->tqp_idle, tqt, tqt_entry);
		if (tqp->tqp_idle_count[lane] > 0)
			twq_lane_idle_adjust_locked(tqp, lane, -1);
	}
	if ((tqt->tqt_flags & TWQT_ACTIVE) != 0 &&
	    tqp->tqp_active_count[lane] > 0)
		twq_lane_active_adjust(tqp, lane, -1);
	if ((tqt->tqt_flags & TWQT_COUNTED) != 0 &&
	    tqp->tqp_total_count[lane] > 0)
		twq_lane_total_adjust_locked(tqp, lane, -1);

	tqt->tqt_flags = 0;
	tqt->tqt_proc = NULL;
	if (tqt->tqt_td != NULL)
		tqt->tqt_td->td_twq = NULL;
}

static void
twq_thread_release(struct thread *td)
{
	struct twq_proc *tqp;
	struct twq_thread *tqt;

	tqt = td->td_twq;
	if (tqt == NULL)
		return;
	tqp = tqt->tqt_proc;
	if (tqp != NULL) {
		mtx_lock(&tqp->tqp_lock);
		twq_thread_dispose_locked(tqt);
		mtx_unlock(&tqp->tqp_lock);
	} else {
		td->td_twq = NULL;
	}
	twq_stats_inc(&twq_thread_state_free_count);
	free(tqt, M_TWQ);
}

static void
twq_proc_release_threads(struct proc *p)
{
	struct thread *td;

	FOREACH_THREAD_IN_PROC(p, td)
		twq_thread_release(td);
}

static struct twq_thread *
twq_thread_get(struct thread *td, struct twq_proc *tqp)
{
	struct twq_thread *tqt;

	tqt = td->td_twq;
	if (tqt != NULL)
		return (tqt);

	tqt = malloc(sizeof(*tqt), M_TWQ, M_WAITOK | M_ZERO);
	tqt->tqt_td = td;
	tqt->tqt_proc = tqp;
	td->td_twq = tqt;
	twq_stats_inc(&twq_thread_state_alloc_count);
	return (tqt);
}

static void
twq_thread_enter_locked(struct twq_proc *tqp, struct twq_thread *tqt, int lane)
{
	int old_lane;

	old_lane = tqt->tqt_lane;
	tqt->tqt_proc = tqp;
	if ((tqt->tqt_flags & TWQT_COUNTED) != 0 && old_lane != lane) {
		if ((tqt->tqt_flags & TWQT_IDLE) != 0) {
			TAILQ_REMOVE(&tqp->tqp_idle, tqt, tqt_entry);
			if (tqp->tqp_idle_count[old_lane] > 0)
				twq_lane_idle_adjust_locked(tqp, old_lane, -1);
			tqt->tqt_flags &= ~TWQT_IDLE;
		}
		if ((tqt->tqt_flags & TWQT_ACTIVE) != 0 &&
		    tqp->tqp_active_count[old_lane] > 0) {
			twq_lane_active_adjust(tqp, old_lane, -1);
			tqt->tqt_flags &= ~TWQT_ACTIVE;
		}
		if (tqp->tqp_total_count[old_lane] > 0)
			twq_lane_total_adjust_locked(tqp, old_lane, -1);
		twq_lane_total_adjust_locked(tqp, lane, 1);
	} else if ((tqt->tqt_flags & TWQT_COUNTED) == 0) {
		twq_lane_total_adjust_locked(tqp, lane, 1);
		tqt->tqt_flags |= TWQT_COUNTED;
	}
	tqt->tqt_lane = lane;
	if ((tqt->tqt_flags & TWQT_IDLE) != 0) {
		TAILQ_REMOVE(&tqp->tqp_idle, tqt, tqt_entry);
		if (tqp->tqp_idle_count[lane] > 0)
			twq_lane_idle_adjust_locked(tqp, lane, -1);
		tqt->tqt_flags &= ~TWQT_IDLE;
	}
	tqt->tqt_flags &= ~TWQT_SWITCH_TRACKED;
	if ((tqt->tqt_flags & TWQT_ACTIVE) == 0) {
		twq_lane_active_adjust(tqp, lane, 1);
		tqt->tqt_flags |= TWQT_ACTIVE;
	}
}

void
twq_thread_switch(struct thread *td, int type, int flags)
{
	struct twq_proc *tqp;
	struct twq_thread *tqt;
	int bucket, lane;

	tqt = td->td_twq;
	if (tqt == NULL || (tqt->tqt_flags & TWQT_COUNTED) == 0)
		return;
	tqp = tqt->tqt_proc;
	if (tqp == NULL)
		return;
	if ((tqt->tqt_flags & TWQT_IDLE) != 0)
		return;

	lane = tqt->tqt_lane;
	if (!twq_lane_is_valid(lane))
		return;
	bucket = twq_lane_bucket(lane);

	switch (type) {
	case TWQ_SWCB_BLOCK:
		if (!twq_switch_tracks_block(flags))
			return;
		tqt->tqt_flags |= TWQT_SWITCH_TRACKED;
		twq_stats_inc(&twq_switch_block_count);
		twq_stats_add_bucket(twq_bucket_switch_block_total, bucket, 1);
		if ((tqt->tqt_flags & TWQT_ACTIVE) != 0) {
			twq_lane_active_adjust(tqp, lane, -1);
			tqt->tqt_flags &= ~TWQT_ACTIVE;
		}
		atomic_store_64(&tqp->tqp_lastblocked_ts[lane], twq_now_usec());
		break;
	case TWQ_SWCB_UNBLOCK:
		if ((tqt->tqt_flags & TWQT_SWITCH_TRACKED) == 0)
			return;
		tqt->tqt_flags &= ~TWQT_SWITCH_TRACKED;
		twq_stats_inc(&twq_switch_unblock_count);
		twq_stats_add_bucket(twq_bucket_switch_unblock_total, bucket, 1);
		if ((tqt->tqt_flags & TWQT_ACTIVE) == 0) {
			twq_lane_active_adjust(tqp, lane, 1);
			tqt->tqt_flags |= TWQT_ACTIVE;
		}
		break;
	default:
		break;
	}
}

static int
twq_copyin_init_args(struct twq_init_args *args, void *uaddr, int ulen)
{
	int error;

	if (uaddr == NULL || ulen < (int)sizeof(*args))
		return (EINVAL);
	error = copyin(uaddr, args, sizeof(*args));
	if (error != 0)
		return (error);
	if (args->tqi_flags & ~TWQ_INIT_SUPPORTED_FLAGS)
		return (ENOTSUP);
	if (args->tqi_version < TWQ_SPI_VERSION_NARROW)
		return (ENOTSUP);
	return (0);
}

static int
twq_copyin_dispatch_config(struct twq_dispatch_config *cfg, void *uaddr, int ulen)
{
	int error;

	if (uaddr == NULL || ulen < (int)sizeof(*cfg))
		return (EINVAL);
	error = copyin(uaddr, cfg, sizeof(*cfg));
	if (error != 0)
		return (error);
	if (cfg->version < TWQ_DISPATCH_MIN_VERSION ||
	    cfg->version > TWQ_DISPATCH_CONFIG_VERSION)
		return (ENOTSUP);
	if (cfg->flags & ~TWQ_DISPATCH_SUPPORTED_FLAGS)
		return (ENOTSUP);
	return (0);
}

static int
twq_copyin_reqthreads_args(struct twq_reqthreads_args *args, void *uaddr, int ulen)
{
	int error;

	if (uaddr == NULL || ulen < (int)sizeof(*args))
		return (EINVAL);
	error = copyin(uaddr, args, sizeof(*args));
	if (error != 0)
		return (error);
	if (args->tqr_flags & ~TWQ_REQTHREADS_SUPPORTED_FLAGS)
		return (ENOTSUP);
	if (args->tqr_version != TWQ_REQTHREADS_VERSION)
		return (ENOTSUP);
	return (0);
}

static int
twq_copyin_thread_transfer_args(struct twq_thread_transfer_args *args,
    void *uaddr, int ulen)
{
	int error;

	if (uaddr == NULL || ulen < (int)sizeof(*args))
		return (EINVAL);
	error = copyin(uaddr, args, sizeof(*args));
	if (error != 0)
		return (error);
	if (args->tqt_flags & ~TWQ_THREAD_TRANSFER_SUPPORTED_FLAGS)
		return (ENOTSUP);
	if (args->tqt_version != TWQ_THREAD_TRANSFER_VERSION)
		return (ENOTSUP);
	return (0);
}

static int
twq_copyin_should_narrow_args(struct twq_should_narrow_args *args, void *uaddr,
    int ulen)
{
	int error;

	if (uaddr == NULL || ulen < (int)sizeof(*args))
		return (EINVAL);
	error = copyin(uaddr, args, sizeof(*args));
	if (error != 0)
		return (error);
	if (args->tqn_flags & ~TWQ_SHOULD_NARROW_SUPPORTED_FLAGS)
		return (ENOTSUP);
	if (args->tqn_version != TWQ_SHOULD_NARROW_VERSION)
		return (ENOTSUP);
	return (0);
}

static int
twq_op_init(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_init_args args;
	struct twq_proc *tqp;
	uint32_t granted;
	int error;

	error = twq_copyin_init_args(&args, uap->arg2, uap->arg3);
	if (error != 0)
		return (error);

	tqp = twq_proc_get(td->td_proc);
	granted = twq_supported_features();
	if (args.tqi_requested_features != 0)
		granted &= args.tqi_requested_features;

	mtx_lock(&tqp->tqp_lock);
	tqp->tqp_flags |= TWQP_CONFIGURED;
	tqp->tqp_features = granted;
	tqp->tqp_spi_version = MIN(args.tqi_version, TWQ_SPI_VERSION_CURRENT);
	tqp->tqp_dispatch_func = (uintptr_t)args.tqi_dispatch_func;
	tqp->tqp_stack_size = args.tqi_stack_size;
	tqp->tqp_guard_size = args.tqi_guard_size;
	mtx_unlock(&tqp->tqp_lock);

	twq_stats_inc(&twq_init_count);
	td->td_retval[0] = granted;
	return (0);
}

static int
twq_op_setup_dispatch(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_dispatch_config cfg;
	struct twq_proc *tqp;
	int error;

	error = twq_copyin_dispatch_config(&cfg, uap->arg2, uap->arg3);
	if (error != 0)
		return (error);

	tqp = twq_proc_get(td->td_proc);
	mtx_lock(&tqp->tqp_lock);
	tqp->tqp_flags |= TWQP_DISPATCH_SETUP;
	tqp->tqp_dispatch_version = cfg.version;
	tqp->tqp_dispatch_flags = cfg.flags;
	tqp->tqp_queue_serialno_offs = cfg.queue_serialno_offs;
	tqp->tqp_queue_label_offs = cfg.queue_label_offs;
	mtx_unlock(&tqp->tqp_lock);

	twq_stats_inc(&twq_setup_dispatch_count);
	td->td_retval[0] = 0;
	return (0);
}

static int
twq_op_thread_enter(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_proc *tqp;
	struct twq_thread *tqt;
	twq_priority_t priority;
	int bucket, lane;

	tqp = td->td_proc->p_twq;
	if (tqp == NULL)
		return (EINVAL);

	priority = (uap->arg3 != 0) ? (uint32_t)uap->arg3 : 0;
	lane = twq_lane_from_priority(priority);
	bucket = twq_lane_bucket(lane);
	tqt = twq_thread_get(td, tqp);

	mtx_lock(&tqp->tqp_lock);
	twq_thread_enter_locked(tqp, tqt, lane);
	mtx_unlock(&tqp->tqp_lock);

	twq_stats_inc(&twq_thread_enter_count);
	twq_stats_add_bucket(twq_bucket_thread_enter_total, bucket, 1);
	td->td_retval[0] = 0;
	return (0);
}

static int
twq_op_reqthreads(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_proc *tqp;
	struct twq_reqthreads_args req;
	twq_priority_t priority;
	register_t admitted;
	uint16_t requested, scheduled;
	int bucket, lane;
	int error;

	tqp = td->td_proc->p_twq;
	if (tqp == NULL)
		return (EINVAL);

	if (uap->arg2 != NULL) {
		error = twq_copyin_reqthreads_args(&req, uap->arg2, uap->arg3);
		if (error != 0)
			return (error);
		requested = twq_clamp_count(req.tqr_reqcount);
		priority = req.tqr_priority;
	} else {
		requested = twq_clamp_count(uap->arg3);
		priority = (uint32_t)uap->arg4;
	}

	lane = twq_lane_from_priority(priority);
	bucket = twq_lane_bucket(lane);

	mtx_lock(&tqp->tqp_lock);
	tqp->tqp_req_count[lane] = requested;
	scheduled = twq_lane_target_locked(tqp, lane, priority);
	tqp->tqp_scheduled_count[lane] = scheduled;
	if (scheduled > tqp->tqp_total_count[lane])
		admitted = scheduled - tqp->tqp_total_count[lane];
	else
		admitted = 0;
	mtx_unlock(&tqp->tqp_lock);

	twq_stats_inc(&twq_reqthreads_count);
	twq_stats_add_bucket(twq_bucket_req_total, bucket, requested);
	twq_stats_add_bucket(twq_bucket_admit_total, bucket, admitted);
	td->td_retval[0] = admitted;
	return (0);
}

static int
twq_op_thread_return(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_proc *tqp;
	struct twq_thread *tqt;
	twq_priority_t priority;
	int bucket, lane, old_lane;

	tqp = td->td_proc->p_twq;
	if (tqp == NULL)
		return (EINVAL);

	priority = (uap->arg3 != 0) ? (uint32_t)uap->arg3 : 0;
	tqt = twq_thread_get(td, tqp);
	lane = twq_lane_from_priority(priority);
	bucket = twq_lane_bucket(lane);
	old_lane = tqt->tqt_lane;

	mtx_lock(&tqp->tqp_lock);
	if ((tqt->tqt_flags & TWQT_IDLE) != 0 &&
	    tqt->tqt_lane != lane) {
		TAILQ_REMOVE(&tqp->tqp_idle, tqt, tqt_entry);
		if (tqp->tqp_idle_count[tqt->tqt_lane] > 0)
			twq_lane_idle_adjust_locked(tqp, tqt->tqt_lane, -1);
		tqt->tqt_flags &= ~TWQT_IDLE;
	}
	if ((tqt->tqt_flags & TWQT_COUNTED) != 0 &&
	    old_lane != lane &&
	    tqp->tqp_total_count[old_lane] > 0)
		twq_lane_total_adjust_locked(tqp, old_lane, -1);

	tqt->tqt_lane = lane;
	tqt->tqt_proc = tqp;
	if ((tqt->tqt_flags & TWQT_ACTIVE) != 0 &&
	    tqp->tqp_active_count[old_lane] > 0) {
		twq_lane_active_adjust(tqp, old_lane, -1);
		tqt->tqt_flags &= ~TWQT_ACTIVE;
	}
	tqt->tqt_flags &= ~TWQT_SWITCH_TRACKED;
	if ((tqt->tqt_flags & TWQT_COUNTED) == 0) {
		twq_lane_total_adjust_locked(tqp, lane, 1);
		tqt->tqt_flags |= TWQT_COUNTED;
	} else if (old_lane != lane) {
		twq_lane_total_adjust_locked(tqp, lane, 1);
	}
	if ((tqt->tqt_flags & TWQT_IDLE) == 0) {
		TAILQ_INSERT_TAIL(&tqp->tqp_idle, tqt, tqt_entry);
		twq_lane_idle_adjust_locked(tqp, lane, 1);
		tqt->tqt_flags |= TWQT_IDLE;
	}
	mtx_unlock(&tqp->tqp_lock);

	twq_stats_inc(&twq_thread_return_count);
	twq_stats_add_bucket(twq_bucket_thread_return_total, bucket, 1);
	td->td_retval[0] = 0;
	return (0);
}

static int
twq_op_thread_transfer(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_proc *tqp;
	struct twq_thread *tqt;
	struct twq_thread_transfer_args args;
	twq_priority_t from_priority, to_priority;
	uint16_t requested;
	int from_lane, to_lane;
	int error;

	tqp = td->td_proc->p_twq;
	if (tqp == NULL)
		return (EINVAL);

	error = twq_copyin_thread_transfer_args(&args, uap->arg2, uap->arg3);
	if (error != 0)
		return (error);

	from_priority = args.tqt_from_priority;
	to_priority = args.tqt_to_priority;
	from_lane = twq_lane_from_priority(from_priority);
	to_lane = twq_lane_from_priority(to_priority);
	if (from_lane == to_lane)
		return (EINVAL);
	requested = twq_clamp_count(args.tqt_from_reqcount);
	tqt = twq_thread_get(td, tqp);

	mtx_lock(&tqp->tqp_lock);
	twq_thread_enter_locked(tqp, tqt, to_lane);
	tqp->tqp_req_count[from_lane] = requested;
	tqp->tqp_scheduled_count[from_lane] =
	    twq_lane_target_locked(tqp, from_lane, from_priority);
	mtx_unlock(&tqp->tqp_lock);

	twq_stats_inc(&twq_thread_transfer_count);
	td->td_retval[0] = 0;
	return (0);
}

static int
twq_op_should_narrow(struct thread *td, struct twq_kernreturn_args *uap)
{
	struct twq_proc *tqp;
	struct twq_should_narrow_args args;
	twq_priority_t priority;
	int lane;
	int error;

	tqp = td->td_proc->p_twq;
	if (tqp == NULL)
		return (EINVAL);

	if (uap->arg2 != NULL) {
		error = twq_copyin_should_narrow_args(&args, uap->arg2, uap->arg3);
		if (error != 0)
			return (error);
		priority = args.tqn_priority;
	} else {
		priority = (uint32_t)uap->arg3;
	}
	lane = twq_lane_from_priority(priority);

	mtx_lock(&tqp->tqp_lock);
	tqp->tqp_scheduled_count[lane] =
	    twq_lane_target_locked(tqp, lane, priority);
	td->td_retval[0] =
	    tqp->tqp_total_count[lane] > tqp->tqp_scheduled_count[lane];
	mtx_unlock(&tqp->tqp_lock);
	twq_stats_inc(&twq_should_narrow_count);
	if (td->td_retval[0] != 0)
		twq_stats_inc(&twq_should_narrow_true_count);
	return (0);
}

int
sys_twq_kernreturn(struct thread *td, struct twq_kernreturn_args *uap)
{

	if (!twq_known_op(uap->op))
		return (EINVAL);
#ifdef THRWORKQ
	switch (uap->op) {
	case TWQ_OP_INIT:
		return (twq_op_init(td, uap));
	case TWQ_OP_THREAD_ENTER:
		return (twq_op_thread_enter(td, uap));
	case TWQ_OP_THREAD_RETURN:
		return (twq_op_thread_return(td, uap));
	case TWQ_OP_THREAD_TRANSFER:
		return (twq_op_thread_transfer(td, uap));
	case TWQ_OP_REQTHREADS:
	case TWQ_OP_REQTHREADS2:
		return (twq_op_reqthreads(td, uap));
	case TWQ_OP_SHOULD_NARROW:
		return (twq_op_should_narrow(td, uap));
	case TWQ_OP_SETUP_DISPATCH:
		return (twq_op_setup_dispatch(td, uap));
	default:
		return (EINVAL);
	}
#else
	return (ENOSYS);
#endif
}

static void
twq_process_init(void *arg __unused, struct proc *p)
{

	p->p_twq = NULL;
}

static void
twq_thread_init(void *arg __unused, struct thread *td)
{

	td->td_twq = NULL;
}

void
twq_proc_exec(struct proc *p)
{
	struct twq_proc *tqp;

	twq_proc_release_threads(p);
	tqp = p->p_twq;
	p->p_twq = NULL;
	if (tqp != NULL)
		twq_proc_free(tqp);
}

void
twq_proc_exit(struct proc *p)
{
	struct twq_proc *tqp;

	twq_proc_release_threads(p);
	tqp = p->p_twq;
	p->p_twq = NULL;
	if (tqp != NULL)
		twq_proc_free(tqp);
}

void
twq_thread_exit(struct thread *td)
{

	twq_thread_release(td);
}

EVENTHANDLER_DEFINE(process_init, twq_process_init, NULL, EVENTHANDLER_PRI_ANY);
EVENTHANDLER_DEFINE(thread_init, twq_thread_init, NULL, EVENTHANDLER_PRI_ANY);
