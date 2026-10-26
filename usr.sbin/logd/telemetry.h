#ifndef LOGD_TELEMETRY_H
#define LOGD_TELEMETRY_H
#include <stdint.h>
#define LOGD_COUNTERS(X) \
 X(dropped_wq) X(dropped_kern_quota) X(dropped_parse) X(bsd_in_truncated) \
 X(store_failed) X(store_fallback_memory) X(file_action_failed) \
 X(native_malformed) X(dup_suppressed) X(config_rejected) X(launchd_dropped) X(sender_dropped)
struct logd_counters {
#define LOGD_FIELD(n) uint64_t n;
 LOGD_COUNTERS(LOGD_FIELD)
#undef LOGD_FIELD
};
extern struct logd_counters logd_counters;
struct logd_delivery { unsigned refs; unsigned duplicate_counted; unsigned file_failure_counted; };
struct logd_delivery *logd_delivery_new(unsigned);
void logd_delivery_begin(struct logd_delivery *);
void logd_delivery_end(void);
void logd_count_duplicate(void);
void logd_count_file_failure(void);
void logd_count_sender_drops(struct asl_msg_s *);
#define LOGD_COUNT(n) ((void)__atomic_fetch_add(&logd_counters.n, 1, __ATOMIC_RELAXED))
void logd_telemetry_snapshot(struct asl_msg_s *);
void logd_telemetry_init(void);
void logd_telemetry_status(void);
void logd_telemetry_flush(void);
void logd_telemetry_record(const char *, const char *, uint64_t);
void asl_out_telemetry(struct asl_msg_s *);
#endif
