/* ABI projection only. Zig owns observation and test assertions. */
#include <paths.h>
#define syslog rmx_observed_syslog
#define vsyslog rmx_observed_vsyslog
#define openlog rmx_observed_openlog
#define closelog rmx_observed_closelog
#define setlogmask rmx_observed_setlogmask
#define __libc_asl_open rmx_observed_asl_open
#define __libc_asl_close rmx_observed_asl_close
#define __libc_asl_send rmx_observed_asl_send
#define __libc_asl_record rmx_observed_asl_record
#define send rmx_observe_send
#include <sys/syslog.h>
#ifndef RMX_SYSLOG_SOURCE
#define RMX_SYSLOG_SOURCE "../../../lib/libc/gen/syslog.c"
#endif
#include RMX_SYSLOG_SOURCE
unsigned rmx_observed_pending(void) { return LogRefused; }
