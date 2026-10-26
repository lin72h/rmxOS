#include "daemon.h"
#include "telemetry.h"
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>

struct logd_counters logd_counters;
static _Thread_local struct logd_delivery *current_delivery;

/* Local datagrams are unauthenticated. This is telemetry only: never use
 * the supplied count to grant privileges, bypass quotas, or change routing. */
void
logd_count_sender_drops(asl_msg_t *m)
{
 const char *s = asl_msg_get_val_for_key(m, "RFC5424.SD.12:rmxos-loss@0.count");
 if (s == NULL) s = asl_msg_get_val_for_key(m, "com.rmxos.syslog.sender_dropped");
 uint64_t count = 0;
 if (s == NULL || *s == '\0') return;
 for (; *s; s++) {
  if (*s < '0' || *s > '9' || count > (UINT64_MAX - (*s - '0')) / 10) return;
  count = count * 10 + (*s - '0');
 }
 uint64_t old = __atomic_load_n(&logd_counters.sender_dropped, __ATOMIC_RELAXED);
 uint64_t next;
 do {
  next = count > UINT64_MAX - old ? UINT64_MAX : old + count;
 } while (!__atomic_compare_exchange_n(&logd_counters.sender_dropped, &old,
     next, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED));
}

struct logd_delivery *
logd_delivery_new(unsigned refs)
{
 struct logd_delivery *d = calloc(1, sizeof(*d));
 if (d) d->refs = refs;
 return d;
}

void
logd_delivery_begin(struct logd_delivery *d)
{
 current_delivery = d;
}

void
logd_delivery_end(void)
{
 struct logd_delivery *d = current_delivery;
 current_delivery = NULL;
 if (d && __atomic_sub_fetch(&d->refs, 1, __ATOMIC_ACQ_REL) == 0) free(d);
}

void
logd_count_duplicate(void)
{
 /* One message can match multiple destinations on both output queues. */
 if (current_delivery && !__atomic_exchange_n(&current_delivery->duplicate_counted, 1, __ATOMIC_RELAXED)) LOGD_COUNT(dup_suppressed);
}

void
logd_count_file_failure(void)
{
 if (!current_delivery || !__atomic_exchange_n(&current_delivery->file_failure_counted, 1, __ATOMIC_RELAXED)) LOGD_COUNT(file_action_failed);
}

/* These records bypass admission, quota and destination/duplicate rules. The
 * action queue still serializes all store access with normal messages. */
void
logd_telemetry_record(const char *kind, const char *counter, uint64_t count)
{
 asl_msg_t *m = asl_msg_new(ASL_TYPE_MSG);
 char value[32];
 if (m == NULL) { LOGD_COUNT(store_failed); return; }
 asl_msg_set_key_val(m, "Sender", "logd");
 asl_msg_set_key_val(m, "Facility", "syslog");
 asl_msg_set_key_val(m, "Level", "5");
 snprintf(value, sizeof(value), "%jd", (intmax_t)time(NULL));
 asl_msg_set_key_val(m, "Time", value);
 asl_msg_set_key_val(m, "org.rmxos.logd.record", kind);
 asl_msg_set_key_val(m, "Message", kind);
 if (counter != NULL) {
  snprintf(value, sizeof(value), "%ju", (uintmax_t)count);
  asl_msg_set_key_val(m, counter, value);
 } else {
/* Values are captured by the action queue immediately before saving. */
 }
 asl_out_telemetry(m);
 asl_msg_release(m);
}

void
logd_telemetry_status(void)
{
 dispatch_async(global.work_queue, ^{
  logd_telemetry_flush();
  logd_telemetry_record("status", NULL, 0);
 });
}

void
logd_telemetry_init(void)
{
 static dispatch_source_t status_timer, flush_timer, signal_source;
 signal(SIGUSR1, SIG_IGN);
 signal_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
 dispatch_source_set_event_handler(signal_source, ^{ logd_telemetry_status(); });
 dispatch_resume(signal_source);
 status_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
 dispatch_source_set_timer(status_timer, dispatch_time(DISPATCH_TIME_NOW, 600ull * NSEC_PER_SEC), 600ull * NSEC_PER_SEC, 0);
 dispatch_source_set_event_handler(status_timer, ^{ logd_telemetry_status(); });
 dispatch_resume(status_timer);
 flush_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global.work_queue);
 dispatch_source_set_timer(flush_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 0);
 dispatch_source_set_event_handler(flush_timer, ^{ logd_telemetry_flush(); });
 dispatch_resume(flush_timer);
}

void
logd_telemetry_snapshot(asl_msg_t *m)
{
 char value[32];
#define LOGD_VALUE(n) \
  snprintf(value, sizeof(value), "%ju", (uintmax_t)__atomic_load_n(&logd_counters.n, __ATOMIC_RELAXED)); \
  asl_msg_set_key_val(m, #n, value);
  LOGD_COUNTERS(LOGD_VALUE)
#undef LOGD_VALUE
}
