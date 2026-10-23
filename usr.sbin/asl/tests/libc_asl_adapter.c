/* ABI projection only; assertions and mocked trap behavior live in Zig. */
#define mach_msg_trap rmx_mach_msg_trap
#define mach_reply_port rmx_reply_port
#define task_self_trap rmx_task_self
#define _kernelrpc_mach_port_deallocate_trap rmx_port_deallocate
#define _kernelrpc_mach_port_destroy_trap rmx_port_destroy
#ifndef RMX_LIBC_ASL_SOURCE
#define RMX_LIBC_ASL_SOURCE "../../../lib/libc/gen/asl_private.c"
#endif
#include RMX_LIBC_ASL_SOURCE
const char *rmx_asl_bytes(void *p) { return ((struct log_request *)p)->bytes.address; }
unsigned rmx_asl_size(void *p) { return ((struct log_request *)p)->bytes.size; }
unsigned rmx_asl_deallocate(void *p) { return ((struct log_request *)p)->bytes.deallocate; }
void rmx_port_reply(void *p, int id, unsigned port)
{
 struct port_reply *r = p;
 memset(r, 0, sizeof(*r));
 r->head.msgh_id = id + 100;
 r->head.msgh_bits = MACH_MSGH_BITS_COMPLEX;
 r->head.msgh_size = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) + sizeof(mach_msg_port_descriptor_t);
 r->body.msgh_descriptor_count = 1;
 r->port.type = MACH_MSG_PORT_DESCRIPTOR;
 r->port.disposition = MACH_MSG_TYPE_PORT_SEND;
 r->port.name = port;
}
