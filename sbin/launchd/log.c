#include <dispatch/dispatch.h>
#include <os/assumes.h>
#include "job_reply.h"

#include "launchd.h"
#include "launch_internal.h"
#include "vproc_internal.h"
#include "log.h"
#include "core.h"
#include <sys/rmx_im.h>

/* A normal versioned relocation can still bind libasl's global export.
 * Resolve the version on the libc handle instead of in the global scope. */
#include <dlfcn.h>
#define LAUNCHD_NATIVE_SYSLOG_LOOKUP 1
typedef void (*launchd_syslog_fn)(int, const char *, ...);
static launchd_syslog_fn _launchd_native_syslog;
static pthread_once_t _launchd_native_syslog_once = PTHREAD_ONCE_INIT;

static void
_launchd_resolve_native_syslog(void)
{
	void *libc = dlopen("libc.so.7", RTLD_LAZY | RTLD_LOCAL);
	if (libc) {
		_launchd_native_syslog = (launchd_syslog_fn)dlvsym(libc, "syslog", "FBSD_1.0");
		/* libc is a permanent dependency; retain the handle for this pointer. */
	}
}

static launchd_syslog_fn
_launchd_get_native_syslog(void)
{
	(void)pthread_once(&_launchd_native_syslog_once, _launchd_resolve_native_syslog);
	return _launchd_native_syslog;
}

#define LAUNCHD_LOGQ_MAX_COUNT 1000
#define LAUNCHD_LOG_PROCESS_SETTLEMENT 1
#define LAUNCHD_LOGQ_MAX_BYTES (256 * 1024)

#define ROUND_TO_64BIT_WORD_SIZE(x)	((x + 7) & ~7)
#define LAUNCHD_DEBUG_LOG "launchd-debug.%s.log"
#define LAUNCHD_PERF_LOG "launchd-perf.%s.log"
#define LAUNCHD_SHUTDOWN_LOG "launchd-shutdown.%s.log"
#define LAUNCHD_LOWLEVEL_LOG "launchd-lowlevel.%s.log"

os_redirect_assumes(_launchd_os_redirect);

const char *launchd_username = "unknown";
const char *launchd_label = "com.apple.launchd.unknown";
mach_port_t launchd_drain_reply_port;
bool launchd_var_available = false;
int64_t launchd_system_start;

static FILE *_launchd_shutdown_log;
static FILE *_launchd_debug_log;
static FILE *_launchd_perf_log;
static STAILQ_HEAD(, logmsg_s) _launchd_logq = STAILQ_HEAD_INITIALIZER(_launchd_logq);
static size_t _launchd_logq_sz;
static size_t _launchd_logq_cnt;
static uint64_t _launchd_logq_dropped;
static pid_t _launchd_drain_pid;
static vm_offset_t _launchd_drain_sent;
static mach_msg_type_number_t _launchd_drain_sent_size;
static uint64_t _launchd_drain_sent_records, _launchd_drain_sent_dropped;
static void _logmsg_remove(struct logmsg_s *lm);

static void
_launchd_log_settle_sent(bool dropped)
{
	if (!_launchd_drain_sent) return;
	if (dropped) {
		uint64_t counts[] = { _launchd_drain_sent_records, _launchd_drain_sent_dropped };
		for (size_t i = 0; i < 2; i++) {
			RMPROBE(UINT64_MAX - _launchd_logq_dropped < counts[i], "log.settle.saturated");
			_launchd_logq_dropped = UINT64_MAX - _launchd_logq_dropped < counts[i] ?
			    UINT64_MAX : _launchd_logq_dropped + counts[i];
		}
	}
	mig_deallocate(_launchd_drain_sent, _launchd_drain_sent_size);
	_launchd_drain_sent = 0;
	_launchd_drain_sent_size = 0;
	_launchd_drain_sent_records = _launchd_drain_sent_dropped = 0;
}

void
launchd_log_process_exit(pid_t pid)
{
	if (pid != _launchd_drain_pid) return;
	_launchd_log_settle_sent(true);
	if (launchd_drain_reply_port) {
		(void)launchd_mport_deallocate(launchd_drain_reply_port);
		launchd_drain_reply_port = MACH_PORT_NULL;
	}
	_launchd_drain_pid = 0;
}

static void
_logmsg_drop(void)
{
	if (_launchd_logq_dropped != UINT64_MAX) _launchd_logq_dropped++;
}

size_t launchd_log_count(void) { return _launchd_logq_cnt; }
size_t launchd_log_bytes(void) { return _launchd_logq_sz; }

uint64_t
launchd_log_dropped(void)
{
	return _launchd_logq_dropped;
}

static void
_logmsg_enqueue(struct logmsg_s *lm)
{
	while (_launchd_logq_cnt >= LAUNCHD_LOGQ_MAX_COUNT ||
	    _launchd_logq_sz > LAUNCHD_LOGQ_MAX_BYTES - lm->obj_sz
#ifdef RMX_INSTRUMENT
	    || (RMBUGGIFY("log.enqueue.full.force") && _launchd_logq_cnt != 0)
#endif
	    ) {
		RMPROBE(true, "log.enqueue.full.drop");
		_logmsg_remove(STAILQ_FIRST(&_launchd_logq));
		_logmsg_drop();
	}
	STAILQ_INSERT_TAIL(&_launchd_logq, lm, sqe);
	_launchd_logq_sz += lm->obj_sz;
	_launchd_logq_cnt++;
}

static bool
_launchd_use_system_log(void)
{
	/* asld is the sole logger; retain early/restart records for its drain. */
	return false;
}

static void
_launchd_system_log(const char *from, pid_t from_pid, const char *about, pid_t about_pid, int pri, const char *msg)
{
	launchd_syslog_fn native = _launchd_get_native_syslog();
	if (native) {
		native(LOG_DAEMON | LOG_PRI(pri), "%s[%u] %s[%u]: %s",
		    from, from_pid, about, about_pid, msg);
	} else if (launchd_console) {
		fprintf(launchd_console, "native syslog unavailable: %s[%u] %s[%u]: %s\n",
		    from, from_pid, about, about_pid, msg);
	}
}
static int _launchd_log_up2 = LOG_UPTO(LOG_NOTICE);

static int64_t _launchd_shutdown_start;

struct _launchd_open_log_ctx_s {
	const char *path;
	FILE **filep;
};

static void
_launchd_open_log_once(void *ctx)
{
	struct _launchd_open_log_ctx_s *ctx2 = ctx;
	const char *path = ctx2->path;
	FILE **filep = ctx2->filep;

	char saved[PATH_MAX];
	snprintf(saved, sizeof(saved), "%s.1", path);
	(void)rename(path, saved);

	FILE *file = fopen(path, "w");
	if (file) {
		(void)_fd(fileno(file));
		*filep = file;
	} else if (launchd_console) {
		fprintf(launchd_console, "Could not open %s: %d: %s\n", path, errno, strerror(errno));
	}
}

static void
_launchd_shutdown_start_once(void *ctx __attribute__((unused)))
{
	_launchd_shutdown_start = runtime_get_wall_time();
}

int
runtime_setlogmask(int maskpri)
{
	_launchd_log_up2 = maskpri;
	return _launchd_log_up2;
}

static bool
_logmsg_add(struct launchd_syslog_attr *attr, int err_num, const char *msg)
{
	size_t lm_sz = sizeof(struct logmsg_s) + strlen(msg) + strlen(attr->from_name) + strlen(attr->about_name) + strlen(attr->session_name) + 4;
	char *data_off;
	struct logmsg_s *lm;

	/* Force the unpacking for the log_drain cause unalignment faults. */
	lm_sz = ROUND_TO_64BIT_WORD_SIZE(lm_sz);
	if (lm_sz > LAUNCHD_LOGQ_MAX_BYTES || RMBUGGIFY("log.add.oversize.force")) {
		RMPROBE(true, "log.add.oversize.drop");
		_logmsg_drop();
		return false;
	}

	if (unlikely(RMBUGGIFY("log.add.alloc.force") || (lm = calloc(1, lm_sz)) == NULL)) {
		RMPROBE(true, "log.add.alloc.failed");
		_logmsg_drop();
		return false;
	}

	data_off = lm->data;

	lm->when = runtime_get_wall_time();
	lm->sender_uid = attr->from_uid;
	lm->sender_gid = getgid();
	lm->from_pid = attr->from_pid;
	lm->about_pid = attr->about_pid;
	lm->err_num = err_num;
	lm->pri = attr->priority;
	lm->obj_sz = lm_sz;
	lm->msg = data_off;
	data_off += sprintf(data_off, "%s", msg) + 1;
	lm->from_name = data_off;
	data_off += sprintf(data_off, "%s", attr->from_name) + 1;
	lm->about_name = data_off;
	data_off += sprintf(data_off, "%s", attr->about_name) + 1;
	lm->session_name = data_off;
	data_off += sprintf(data_off, "%s", attr->session_name) + 1;

	_logmsg_enqueue(lm);

	return true;
}

static void
_logmsg_remove(struct logmsg_s *lm)
{
	STAILQ_REMOVE(&_launchd_logq, lm, logmsg_s, sqe);
	_launchd_logq_sz -= lm->obj_sz;
	_launchd_logq_cnt--;

	free(lm);
}

bool
_launchd_os_redirect(const char *message)
{
	launchd_syslog(LOG_ERR, "%s", message);
	return true;
}

void
launchd_syslog(int pri, const char *message, ...)
{
	struct launchd_syslog_attr attr = {
		.from_name = launchd_label,
		.about_name = launchd_label,
		.session_name = pid1_magic ? "System" : "Background",
		.priority = pri,
		.from_uid = launchd_uid,
		.from_pid = getpid(),
		.about_pid = getpid(),
	};

	va_list ap;

	va_start(ap, message);
	launchd_vsyslog(&attr, message, ap);
	va_end(ap);
}

void
launchd_vsyslog(struct launchd_syslog_attr *attr, const char *fmt, va_list args)
{
	int saved_errno = errno;
	char message[2048];

	static dispatch_once_t perf_once = 0;
	static dispatch_once_t shutdown_once = 0;
	static dispatch_once_t shutdown_start_once = 0;
	static dispatch_once_t debug_once = 0;

	bool echo2console = (attr->priority & LOG_CONSOLE);
	attr->priority &= ~LOG_CONSOLE;
	if (attr->priority == LOG_APPLEONLY && launchd_apple_internal) {
		attr->priority = LOG_NOTICE;
	}

	FILE *log2here = NULL;

	/* launchctl is responsible for mounting /var as read-write. So we need to
	 * wait until /var/log is available before trying to log anything to our log
	 * anything to our auxilliary log files. This is kind of a hack because
	 * we'll lose the first few relevant messages at boot for debug and
	 * performance logging, but the loss isn't too bad. 
	 */
	if (launchd_var_available && !RMBUGGIFY("log.vsyslog.prevar.force")) {
		/* This file is for logging low-level errors where we can't necessarily be
		 * assured that we can write to the console or use syslog.
		 */
		char *store = launchd_copy_persistent_store(LAUNCHD_PERSISTENT_STORE_LOGS, NULL);
		char path[PATH_MAX];

		if (attr->priority == LOG_PERF) {
			if (launchd_log_perf) {
				(void)snprintf(path, sizeof(path), "%s" LAUNCHD_PERF_LOG, store, launchd_username);

				struct _launchd_open_log_ctx_s ctx2 = {
					.path = path,
					.filep = &_launchd_perf_log,
				};
				dispatch_once_f(&perf_once, &ctx2, _launchd_open_log_once);
				log2here = _launchd_perf_log;
			}

			// Don't log performance messages to the normal syslog store.
			attr->priority = LOG_DEBUG + 1;
		} else {
			if (launchd_shutting_down && launchd_log_shutdown) {
				dispatch_once_f(&shutdown_start_once, NULL, _launchd_shutdown_start_once);

				(void)snprintf(path, sizeof(path), "%s" LAUNCHD_SHUTDOWN_LOG, store, launchd_username);

				struct _launchd_open_log_ctx_s ctx2 = {
					.path = path,
					.filep = &_launchd_shutdown_log,
				};
				dispatch_once_f(&shutdown_once, &ctx2, _launchd_open_log_once);
				log2here = _launchd_shutdown_log;
			} else if (launchd_log_debug) {
				(void)snprintf(path, sizeof(path), "%s" LAUNCHD_DEBUG_LOG, store, launchd_username);

				struct _launchd_open_log_ctx_s ctx2 = {
					.path = path,
					.filep = &_launchd_debug_log,
				};
				dispatch_once_f(&debug_once, &ctx2, _launchd_open_log_once);
				log2here = _launchd_debug_log;
			}
		}

		free(store);
#ifdef RMX_INSTRUMENT
	} else {
		RMPROBE(true, "log.vsyslog.prevar");
#endif
	}

	vsnprintf(message, sizeof(message), fmt, args);
	if (echo2console && launchd_console) {
		fprintf(launchd_console, "%-32s %-8u %-64s %-8u  %s\n", attr->from_name, attr->from_pid, attr->about_name, attr->about_pid, message);
	}

	if (log2here) {
		int64_t delta = 0;
		if (log2here == _launchd_shutdown_log) {
			delta = runtime_get_wall_time() - _launchd_shutdown_start;
		} else {
			delta = runtime_get_wall_time() - launchd_system_start;
		}

		fprintf(log2here, "%-8zd %-32s %-8u %-24s %-8u  %s\n", delta, attr->from_name, attr->from_pid, attr->about_name, attr->about_pid, message);
	}

	if ((LOG_MASK(attr->priority) & _launchd_log_up2)) {
		if (_launchd_use_system_log()) {
			_launchd_system_log(attr->from_name, attr->from_pid, attr->about_name, attr->about_pid, attr->priority, message);
		} else {
			_logmsg_add(attr, saved_errno, message);
		}
	}
}

static kern_return_t
_launchd_log_pack(vm_offset_t *outval, mach_msg_type_number_t *outvalCnt)
{
	struct logmsg_s *lm;
	uint8_t *offset;

	uint64_t dropped = launchd_log_dropped();
	char report[96];
	size_t report_size = 0;
	if (dropped) {
		snprintf(report, sizeof(report), "launchd log queue dropped %ju records", (uintmax_t)dropped);
		report_size = ROUND_TO_64BIT_WORD_SIZE(sizeof(struct logmsg_s) + strlen(report) +
		    2 * strlen("com.apple.launchd") + strlen("System") + 4);
	}
	*outvalCnt = _launchd_logq_sz + report_size;
	if (RMBUGGIFY("log.pack.allocate.force")) *outval = 0;
	else mig_allocate(outval, *outvalCnt);
	if (unlikely(*outval == 0)) {
		RMPROBE(true, "log.pack.allocate.failed");
		return KERN_RESOURCE_SHORTAGE;
	}
	offset = (uint8_t *)*outval;
	if (dropped) {
		lm = (struct logmsg_s *)offset;
		memset(lm, 0, report_size);
		lm->obj_sz = report_size;
		lm->when = runtime_get_wall_time();
		lm->from_pid = getpid();
		lm->about_pid = getpid();
		lm->pri = LOG_WARNING;
		char *p = lm->data;
		lm->msg_offset = p - (char *)lm; p += sprintf(p, "%s", report) + 1;
		lm->from_name_offset = p - (char *)lm; p += sprintf(p, "com.apple.launchd") + 1;
		lm->about_name_offset = p - (char *)lm; p += sprintf(p, "com.apple.launchd") + 1;
		lm->session_name_offset = p - (char *)lm; strcpy(p, "System");
		offset += report_size;
		_launchd_logq_dropped = 0;
	}
	while ((lm = STAILQ_FIRST(&_launchd_logq))) {
		lm->from_name_offset = lm->from_name - (char *)lm;
		lm->about_name_offset = lm->about_name - (char *)lm;
		lm->msg_offset = lm->msg - (char *)lm;
		lm->session_name_offset = lm->session_name - (char *)lm;

		memcpy(offset, lm, lm->obj_sz);

		offset += lm->obj_sz;

		_logmsg_remove(lm);
	}

	return 0;
}

static void
_launchd_log_uncork_pending_drain(void)
{
	mach_msg_type_number_t outvalCnt;
	mach_port_t tmp_port;
	vm_offset_t outval;

	if (!launchd_drain_reply_port) {
		return;
	}

	if (_launchd_logq_cnt == 0 && launchd_log_dropped() == 0) {
		return;
	}

	uint64_t pending_drops = launchd_log_dropped();
	uint64_t pending_records = _launchd_logq_cnt;
	if (_launchd_log_pack(&outval, &outvalCnt) != 0) {
		return;
	}

	tmp_port = launchd_drain_reply_port;
	launchd_drain_reply_port = MACH_PORT_NULL;
	if ((errno = RMBUGGIFY("log.reply.failed.force") ? KERN_FAILURE :
	    job_mig_log_drain_reply(tmp_port, 0, outval, outvalCnt)) != 0) {
		/* Every undelivered record must be represented in the next report. */
		for (size_t n = 0; n < outvalCnt; ) {
			RMPROBE(true, "log.reply.failed.walk");
			struct logmsg_s *lost = (void *)(outval + n);
			if (n == 0 && pending_drops != 0) {
				_launchd_logq_dropped = UINT64_MAX - _launchd_logq_dropped < pending_drops ?
				    UINT64_MAX : _launchd_logq_dropped + pending_drops;
			} else _logmsg_drop();
			n += lost->obj_sz;
		}
		(void)launchd_mport_deallocate(tmp_port);
	} else {
		/* The next request from this process acknowledges its callbacks. */
		_launchd_drain_sent = outval;
		_launchd_drain_sent_size = outvalCnt;
		_launchd_drain_sent_records = pending_records;
		_launchd_drain_sent_dropped = pending_drops;
		return;
	}

	mig_deallocate(outval, outvalCnt);
}

void
launchd_log_push(void)
{
	vm_offset_t outval = 0;
	mach_msg_type_number_t outvalCnt = 0;

	if (!pid1_magic) {
		if (_launchd_perf_log) {
			(void)fflush(_launchd_perf_log);
		}
		if (_launchd_shutdown_log) {
			(void)fflush(_launchd_shutdown_log);
		}
		if (_launchd_debug_log) {
			(void)fflush(_launchd_debug_log);
		}

		if (_launchd_logq_cnt && _launchd_log_pack(&outval, &outvalCnt) == 0) {
			(void)_vprocmgr_log_forward(inherited_bootstrap_port, (void *)outval, outvalCnt);
			mig_deallocate(outval, outvalCnt);
		}
	} else {
		if (_launchd_use_system_log()) {
			struct logmsg_s *lm;
			while ((lm = STAILQ_FIRST(&_launchd_logq))) {
				_launchd_system_log(lm->from_name, lm->from_pid, lm->about_name, lm->about_pid, lm->pri, lm->msg);
				_logmsg_remove(lm);
			}
		} else {
			_launchd_log_uncork_pending_drain();
		}
	}
}

/* Count the damaged frame and every frame after it. If a frame is invalid,
 * count that undecodable span once and resume at the next aligned,
 * fully valid record. Destroyed framing cannot reveal additional boundaries.
 */
static void
_logmsg_drop_forwarded_tail(const uint8_t *bytes, size_t left)
{
	while (left != 0) {
		_logmsg_drop();
		const struct logmsg_s *lm = (const void *)bytes;
		size_t size;
		if (launchd_log_record_valid(lm, left) && !RMBUGGIFY("log.forward.rescan.force")) {
			size = lm->obj_sz;
		} else {
			RMPROBE(true, "log.forward.rescan");
			for (size = 8; size < left; size += 8) {
				if (launchd_log_record_valid((const void *)(bytes + size), left - size)) break;
			}
			if (size >= left) {
				RMPROBE(true, "log.forward.rescan.give-up");
				return;
			}
		}
		bytes += size;
		left -= size;
	}
}

kern_return_t
launchd_log_forward(uid_t forward_uid, gid_t forward_gid, vm_offset_t inval, mach_msg_type_number_t invalCnt)
{
	struct logmsg_s *lm, *lm_walk;
	mach_msg_type_number_t data_left = invalCnt;

	if (inval == 0) {
		return 0;
	}

	for (lm_walk = (struct logmsg_s *)inval; data_left > 0; lm_walk = (struct logmsg_s *)((uint64_t *)lm_walk + lm_walk->obj_sz/8)) {
		if (!launchd_log_record_valid(lm_walk, data_left)) {
			_logmsg_drop_forwarded_tail((const void *)lm_walk, data_left);
			break;
		}

		if (lm_walk->obj_sz > LAUNCHD_LOGQ_MAX_BYTES) {
			RMPROBE(true, "log.forward.oversize.drop");
			_logmsg_drop();
			data_left -= lm_walk->obj_sz;
			continue;
		}

		if (!(lm = malloc(lm_walk->obj_sz))) {
			_logmsg_drop_forwarded_tail((const void *)lm_walk, data_left);
			break;
		}

		memcpy(lm, lm_walk, lm_walk->obj_sz);
		lm->sender_uid = forward_uid;
		lm->sender_gid = forward_gid;

		lm->from_name += (size_t)lm;
		lm->about_name += (size_t)lm;
		lm->msg += (size_t)lm;
		lm->session_name += (size_t)lm;

		if (_launchd_use_system_log()) {
			_launchd_system_log(lm->from_name, lm->from_pid, lm->about_name, lm->about_pid, lm->pri, lm->msg);
			free(lm);
		} else {
			_logmsg_enqueue(lm);
		}

		/* The copied record may already have been freed by native logging. */
		data_left -= lm_walk->obj_sz;
	}

	mig_deallocate(inval, invalCnt);

	return 0;
}

kern_return_t
launchd_log_drain(pid_t pid, mach_port_t srp, vm_offset_t *outval, mach_msg_type_number_t *outvalCnt)
{
	*outval = 0;
	*outvalCnt = 0;
	if (launchd_drain_reply_port != MACH_PORT_NULL) {
		RMPROBE(true, "log.drain.pending.refused");
		return KERN_RESOURCE_SHORTAGE;
	}
	if (_launchd_drain_sent && pid != _launchd_drain_pid) {
		RMPROBE(true, "log.drain.other-pid.refused");
		return KERN_RESOURCE_SHORTAGE;
	}
	if (pid <= 0 || launchd_log_watch_process(pid) != 0) {
		RMPROBE(true, "log.drain.watch.refused");
		return KERN_RESOURCE_SHORTAGE;
	}
	_launchd_log_settle_sent(false);
	_launchd_drain_pid = pid;
	launchd_drain_reply_port = srp;
	_launchd_log_uncork_pending_drain();
	return MIG_NO_REPLY;
}

void
launchd_closelog(void)
{
	launchd_log_push();

	if (_launchd_shutdown_log) {
		(void)fflush(_launchd_shutdown_log);
		(void)runtime_fsync(fileno(_launchd_shutdown_log));
	}
}
