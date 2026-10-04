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
bool pid1_magic;
static bool test_drainer;
bool launchd_asl_drainer_running(void) { return test_drainer; }
int rmx_route(int pid1, int running) {
 pid1_magic = pid1; test_drainer = running;
#ifdef LAUNCHD_LOGQ_MAX_COUNT
 return _launchd_use_system_log();
#else
 return 0;
#endif
}
void rmx_queue_numbered(unsigned count) {
 struct launchd_syslog_attr attr = {.from_name="test", .about_name="test", .session_name="System", .priority=LOG_NOTICE};
 char text[32];
 for (unsigned i=0; i<count; i++) { snprintf(text,sizeof(text),"%u",i); _logmsg_add(&attr,0,text); }
}
unsigned rmx_queue_oldest(void) { return strtoul(STAILQ_FIRST(&_launchd_logq)->msg,NULL,10); }
#include <dlfcn.h>
#include <asl.h>
void *rmx_asl_anchor(void) { return (void *)asl_open; }
const char *rmx_native_log_library(void) {
 Dl_info info;
#ifdef LAUNCHD_NATIVE_SYSLOG_LOOKUP
 void *fn = (void *)_launchd_get_native_syslog();
#else
 void *fn = (void *)launchd_native_syslog;
#endif
 if (dladdr(fn,&info)==0) return "";
 return info.dli_fname;
}
