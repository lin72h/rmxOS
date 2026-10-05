/* Test-only ABI projection. Scheduling and observations belong to Zig. */
#ifndef OP500_PROJECTION_H
#define OP500_PROJECTION_H
#include <mach/mach.h>
#include <stddef.h>
struct op500_hooks {
 void (*before_handler)(void *);
 void (*after_receive)(void *, int);
 mach_msg_return_t (*receive)(mach_msg_header_t *, mach_msg_option_t,
     mach_msg_size_t, mach_msg_size_t, mach_port_name_t,
     mach_msg_timeout_t, mach_port_name_t);
 void (*unpack)(void *, size_t);
 void (*source_cancelled)(void *);
 void (*port_release)(void *, unsigned, unsigned);
 void (*pending_free)(void *);
};
void op500_install(const struct op500_hooks *);
void op500_before_handler(void *);
void op500_after_receive(void *, int);
mach_msg_return_t op500_receive(mach_msg_header_t *, mach_msg_option_t,
    mach_msg_size_t, mach_msg_size_t, mach_port_name_t,
    mach_msg_timeout_t, mach_port_name_t);
void op500_unpack(void *, size_t);
void op500_source_cancelled(void *);
void op500_port_release(void *, unsigned, unsigned);
void op500_pending_free(void *);
#endif
