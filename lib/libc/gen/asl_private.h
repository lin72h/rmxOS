/* Private libc logging backend. Call with syslog_mutex held. */
#ifndef LIBC_ASL_PRIVATE_H
#define LIBC_ASL_PRIVATE_H
#include <sys/time.h>
#include <stdint.h>
__attribute__((visibility("hidden"))) int __libc_asl_send(const char *);
__attribute__((visibility("hidden"))) char *__libc_asl_record(const char *, int,
    int, const struct timeval *, const char *, const char *, uint64_t);
#endif
