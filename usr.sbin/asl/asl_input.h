/* Shared bounded input operations used by asld and its regression harness. */
#ifndef ASL_INPUT_H
#define ASL_INPUT_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#define ASL_SOCKET_MAX 8192
#define ASL_KLOG_SIZE 4096
struct asl_klog_state { char bytes[ASL_KLOG_SIZE + 1]; size_t used; };
typedef void (*asl_input_emit_t)(const char *, size_t, void *);
ssize_t asl_bsd_receive(int, char *, uint64_t *);
ssize_t asl_klog_read(int, struct asl_klog_state *, asl_input_emit_t, void *);
#endif
