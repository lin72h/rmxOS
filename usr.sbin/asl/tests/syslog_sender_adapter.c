/* Host ABI projection of the production libc sender onto a test socket. */
#include <paths.h>
static const char *rmx_socket_path;
#undef _PATH_LOG
#define _PATH_LOG rmx_socket_path
#define syslog rmx_sender_syslog
#define vsyslog rmx_sender_vsyslog
#define openlog rmx_sender_openlog
#define closelog rmx_sender_closelog
#define setlogmask rmx_sender_setlogmask
#define __libc_asl_send rmx_sender_asl_unavailable
#include <sys/syslog.h>
#undef _PATH_LOG
#define _PATH_LOG rmx_socket_path
#ifndef RMX_SYSLOG_SOURCE
#define RMX_SYSLOG_SOURCE "../../../lib/libc/gen/syslog.c"
#endif
#include RMX_SYSLOG_SOURCE

void rmx_sender_path(const char *path) { rmx_socket_path = path; }
int rmx_sender_asl_unavailable(const char *record) { (void)record; return -1; }
int rmx_sender_buffer(int size) { return _setsockopt(LogFile, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)); }
