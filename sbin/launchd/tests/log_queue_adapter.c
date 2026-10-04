/* ABI projection for Zig tests of the actual log.c queue. */
#include "../log.c"
int64_t runtime_get_wall_time(void) { return 0; }
void rmx_queue_clear(void) {
 struct logmsg_s *lm;
 while ((lm = STAILQ_FIRST(&_launchd_logq))) _logmsg_remove(lm);
#ifdef LAUNCHD_LOGQ_MAX_COUNT
 _launchd_logq_dropped = 0;
#endif
}
void rmx_queue_add(unsigned count, unsigned bytes) {
 char *msg = malloc((size_t)bytes + 1);
 memset(msg, 'x', bytes); msg[bytes] = 0;
 struct launchd_syslog_attr attr = {.from_name="test", .about_name="test", .session_name="System", .priority=LOG_NOTICE};
 for (unsigned i=0; i<count; i++) _logmsg_add(&attr, 0, msg);
 free(msg);
}
void rmx_queue_facts(uint64_t *out) {
 out[0] = _launchd_logq_cnt; out[1] = _launchd_logq_sz;
#ifdef LAUNCHD_LOGQ_MAX_COUNT
 out[2] = _launchd_logq_dropped;
#else
 out[2] = 0;
#endif
}
