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

#ifdef LAUNCHD_LOG_PROCESS_SETTLEMENT
 _launchd_log_settle_sent(false);
 _launchd_drain_pid = 0;
#endif
 launchd_drain_reply_port = MACH_PORT_NULL;
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
static bool test_send_success;
static unsigned test_sent_records;
kern_return_t job_mig_log_drain_reply(mach_port_t port, kern_return_t rc, vm_offset_t bytes, mach_msg_type_number_t size) {
 (void)port; (void)rc;
 if (!test_send_success) return KERN_FAILURE;
 for (size_t n = 0; n < size; ) { test_sent_records++; n += ((struct logmsg_s *)(bytes + n))->obj_sz; }
 return KERN_SUCCESS;
}
int launchd_log_watch_process(pid_t pid) { (void)pid; return 0; }
kern_return_t launchd_mport_notify_req(mach_port_t port, mach_msg_id_t notification) { (void)port; (void)notification; return 0; }
int rmx_drain_request(int pid, unsigned port) {
 vm_offset_t bytes; mach_msg_type_number_t size;
 test_send_success = true;
#ifdef LAUNCHD_LOG_PROCESS_SETTLEMENT
 int result = launchd_log_drain(pid, port, &bytes, &size);
#else
 (void)pid;
 int result = launchd_log_drain(port, &bytes, &size);
#endif
 test_send_success = false;
 return result;
}
void rmx_drain_exit(int pid) {
#ifdef LAUNCHD_LOG_PROCESS_SETTLEMENT
 launchd_log_process_exit(pid);
#else
 (void)pid;
#endif
}
unsigned rmx_drain_held(void) {
#ifdef LAUNCHD_LOG_PROCESS_SETTLEMENT
 return _launchd_drain_sent_records;
#else
 return 0;
#endif
}
unsigned rmx_drain_sent(void) { return test_sent_records; }
kern_return_t launchd_mport_deallocate(mach_port_t port) { (void)port; return 0; }
void rmx_bad_forward(unsigned mode) {
 vm_offset_t bytes = 0; mach_msg_type_number_t length = 0;
 rmx_queue_add(mode == 5 ? 3 : 2, 20);
 _launchd_log_pack(&bytes, &length);
 struct logmsg_s *first = (void *)bytes;
 if (mode == 0) first->msg_offset = first->obj_sz;
 if (mode == 1) first->obj_sz = 0;
 if (mode == 2) first->obj_sz = 8;
 if (mode == 3) test_malloc_remaining = 0;
 if (mode == 4) test_malloc_remaining = 1;
 if (mode == 5) { first->msg_offset = 0; first->obj_sz *= 2; }
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

/* Read-only instrumentation ABI; assertions and formatting live in Zig. */
size_t rmx_im_count(void) {
#ifdef RMX_INSTRUMENT
 return (size_t)(__stop_rmx_im_sites - __start_rmx_im_sites);
#else
 return 0;
#endif
}
const char *rmx_im_text(size_t index, unsigned field) {
#ifdef RMX_INSTRUMENT
 if (index < rmx_im_count()) return field ? __start_rmx_im_sites[index].comment : __start_rmx_im_sites[index].file;
#else
 (void)index; (void)field;
#endif
 return "";
}
uint64_t rmx_im_value(size_t index, unsigned field) {
#ifdef RMX_INSTRUMENT
 if (index >= rmx_im_count()) return 0;
 struct rmx_im_site *site = &__start_rmx_im_sites[index];
 switch (field) {
 case 0: return __atomic_load_n(&site->hits, __ATOMIC_RELAXED);
 case 1: return __atomic_load_n(&site->checks, __ATOMIC_RELAXED);
 case 2: return site->line;
 case 3: return site->ordinal;
 case 4: return site->kind;
 }
#else
 (void)index; (void)field;
#endif
 return 0;
}
int rmx_pack_status(void) {
 vm_offset_t bytes = 0; mach_msg_type_number_t size = 0;
 int result = _launchd_log_pack(&bytes, &size);
 if (result == 0) mig_deallocate(bytes, size);
 return result;
}
