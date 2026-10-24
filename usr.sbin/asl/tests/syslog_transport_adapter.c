/* ABI projection of the production backend; observations are implemented in Zig. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/mach/message.h>
#include <unistd.h>
extern mach_msg_return_t rmx_observe_trap(mach_msg_header_t *, mach_msg_option_t,
    mach_msg_size_t, mach_msg_size_t, mach_port_t, mach_msg_timeout_t, mach_port_t);
extern ssize_t rmx_observe_send(int, const void *, size_t, int);
#define __sys_task_self_trap rmx_observe_task
#define __sys_mach_reply_port rmx_observe_reply
#define __sys__kernelrpc_mach_port_deallocate_trap rmx_observe_deallocate
#define __sys_mach_msg_trap rmx_observe_trap
#define __libc_asl_open rmx_observed_asl_open
#define __libc_asl_close rmx_observed_asl_close
#define __libc_asl_send rmx_observed_asl_send
#define __libc_asl_record rmx_observed_asl_record
#ifndef RMX_LIBC_ASL_SOURCE
#define RMX_LIBC_ASL_SOURCE "../../../lib/libc/gen/asl_private.c"
#endif
#include RMX_LIBC_ASL_SOURCE
