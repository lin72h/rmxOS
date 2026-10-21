/* ABI projection for Zig tests of the actual log.c queue. */
#include <stdlib.h>
static int test_malloc_remaining = -1;
static void *test_malloc(size_t size) {
 if (test_malloc_remaining == 0) return NULL;
 if (test_malloc_remaining > 0) test_malloc_remaining--;
 return malloc(size);
}
#define malloc test_malloc
#include "../log.c"
FILE *launchd_console;
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
void mig_allocate(vm_address_t *address, vm_size_t size) { *address = (vm_address_t)calloc(1, size); }
void rmx_queue_pack(uint64_t *out) {
 vm_offset_t bytes = 0; mach_msg_type_number_t length = 0;
 out[0] = _launchd_logq_cnt; out[1] = 0;
 if (_launchd_log_pack(&bytes, &length) == 0) {
  struct logmsg_s *lm = (void *)bytes;
  const char *text = (char *)lm + lm->msg_offset;
  unsigned long long dropped = 0;
  if (sscanf(text, "launchd log queue dropped %llu records", &dropped) == 1) out[1] = dropped;
  free((void *)bytes);
 }
 out[2] = _launchd_logq_cnt;
 out[3] = launchd_log_dropped();
}
int rmx_record_valid(void *record, size_t length) { return launchd_log_record_valid(record, length); }
void mig_deallocate(vm_address_t address, vm_size_t size) { (void)size; free((void *)address); }
kern_return_t job_mig_log_drain_reply(mach_port_t port, kern_return_t rc, vm_offset_t bytes, mach_msg_type_number_t size) {
 (void)port; (void)rc; (void)bytes; (void)size; return KERN_FAILURE;
}
kern_return_t launchd_mport_deallocate(mach_port_t port) { (void)port; return 0; }
void rmx_bad_forward(unsigned mode) {
 vm_offset_t bytes = 0; mach_msg_type_number_t length = 0;
 rmx_queue_add(2, 20);
 _launchd_log_pack(&bytes, &length);
 struct logmsg_s *first = (void *)bytes;
 if (mode == 0) first->msg_offset = first->obj_sz;
 if (mode == 1) first->obj_sz = 0;
 if (mode == 2) first->obj_sz = 8;
 if (mode == 3) test_malloc_remaining = 0;
 if (mode == 4) test_malloc_remaining = 1;
 launchd_log_forward(0, 0, bytes, length);
 test_malloc_remaining = -1;
}
void rmx_failed_report_send(unsigned pending) {
 struct launchd_syslog_attr attr = {.from_name="com.apple.launchd", .from_pid=1, .about_name="job", .about_pid=123, .session_name="System", .priority=LOG_NOTICE};
 _launchd_logq_dropped = pending;
 _logmsg_add(&attr, 0, "launchd log queue dropped 7 records");
 launchd_drain_reply_port = 42;
 _launchd_log_uncork_pending_drain();
}
