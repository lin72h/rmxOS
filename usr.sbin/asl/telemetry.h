#ifndef ASLD_TELEMETRY_H
#define ASLD_TELEMETRY_H
#include <stdint.h>
#define ASLD_COUNTERS(X) \
 X(dropped_wq) X(dropped_kern_quota) X(dropped_parse) X(bsd_in_truncated) \
 X(store_failed) X(store_fallback_memory) X(file_action_failed) \
 X(native_malformed) X(dup_suppressed) X(config_rejected) X(launchd_dropped) X(sender_dropped)
struct asld_counters {
#define ASLD_FIELD(n) uint64_t n;
 ASLD_COUNTERS(ASLD_FIELD)
#undef ASLD_FIELD
};
extern struct asld_counters asld_counters;
struct asld_delivery { unsigned refs; unsigned duplicate_counted; unsigned file_failure_counted; };
struct asld_delivery *asld_delivery_new(unsigned);
void asld_delivery_begin(struct asld_delivery *);
void asld_delivery_end(void);
void asld_count_duplicate(void);
void asld_count_file_failure(void);
void asld_count_sender_drops(struct asl_msg_s *);
#define ASLD_COUNT(n) ((void)__atomic_fetch_add(&asld_counters.n, 1, __ATOMIC_RELAXED))
void asld_telemetry_snapshot(struct asl_msg_s *);
void asld_telemetry_init(void);
void asld_telemetry_status(void);
void asld_telemetry_flush(void);
void asld_telemetry_record(const char *, const char *, uint64_t);
void asl_out_telemetry(struct asl_msg_s *);
#endif
