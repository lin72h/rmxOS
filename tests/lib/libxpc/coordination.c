/* C ABI and Blocks projections only; no test scheduling or assertions. */
#include <sys/types.h>
#include <sys/queue.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <xpc/xpc.h>
#include "xpc_internal.h"
#include "projection.h"
#include <servers/bootstrap.h>
static struct op500_hooks hooks;
void op500_install(const struct op500_hooks *h) { hooks = *h; }
void op500_before_handler(void *p) { if (hooks.before_handler) hooks.before_handler(p); }
void op500_after_receive(void *p, int r) { if (hooks.after_receive) hooks.after_receive(p, r); }
mach_msg_return_t op500_receive(mach_msg_header_t *h, mach_msg_option_t o,
    mach_msg_size_t s, mach_msg_size_t r, mach_port_name_t p,
    mach_msg_timeout_t t, mach_port_name_t n) {
 return hooks.receive ? hooks.receive(h,o,s,r,p,t,n) : mach_msg(h,o,s,r,p,t,n);
}
void op500_unpack(void *p,size_t n) { if (hooks.unpack) hooks.unpack(p,n); }
void op500_source_cancelled(void *p) { if (hooks.source_cancelled) hooks.source_cancelled(p); }
void op500_port_release(void *p,unsigned n,unsigned kind) { if (hooks.port_release) hooks.port_release(p,n,kind); }
void op500_pending_free(void *p) { if (hooks.pending_free) hooks.pending_free(p); }
kern_return_t op502_lookup(mach_port_t p,const char *n,mach_port_t *r) { return hooks.lookup ? hooks.lookup(p,n,r) : bootstrap_look_up(p,(char *)n,r); }
void op500_event_handler(xpc_connection_t,void *,void (*)(void *,xpc_object_t));
void op500_reply(xpc_connection_t,xpc_object_t,dispatch_queue_t,void *,void (*)(void *,xpc_object_t));
void op500_event_handler(xpc_connection_t c,void *ctx,void (*f)(void *,xpc_object_t)) {
 xpc_connection_set_event_handler(c, ^(xpc_object_t o) { f(ctx,o); });
}
void op500_reply(xpc_connection_t c,xpc_object_t o,dispatch_queue_t q,void *ctx,void (*f)(void *,xpc_object_t)) {
 xpc_connection_send_message_with_reply(c,o,q, ^(xpc_object_t r) { f(ctx,r); });
}
void op507_barrier(xpc_connection_t c,void *ctx,void (*f)(void *)) {
 xpc_connection_send_barrier(c, ^{ f(ctx); });
}
