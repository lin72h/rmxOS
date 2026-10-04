/* C ABI projection only. Zig owns control scheduling and observations. */
#include <sys/types.h>
#include <sys/event.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <pthread.h>
void op468_change(int, unsigned, uint64_t, uint64_t);
void op468_event(int, unsigned, uintptr_t, uintptr_t, unsigned);
void op468_move(unsigned);
void op468_deallocate(unsigned);
void op468_received(unsigned, unsigned, unsigned, int);
void op468_registered(unsigned, unsigned, int);
void op468_notification(unsigned, unsigned, unsigned);
void op478_previous(unsigned, unsigned, unsigned, int);
int op478_receive(mach_msg_header_t *, unsigned, int);
static int (*real_kevent)(int,const struct kevent*,int,struct kevent*,int,const struct timespec*);
static kern_return_t (*real_move)(mach_port_t,mach_port_t,mach_port_t);
static kern_return_t (*real_deallocate)(mach_port_t,mach_port_t);
static kern_return_t (*real_notification)(mach_port_t,mach_port_t,mach_msg_id_t,mach_port_mscount_t,mach_port_t,mach_msg_type_name_t,mach_port_t*);
static mach_msg_return_t (*real_msg)(mach_msg_header_t *,mach_msg_option_t,mach_msg_size_t,mach_msg_size_t,mach_port_name_t,mach_msg_timeout_t,mach_port_name_t);
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void resolve(void) {
 real_msg=dlsym(RTLD_NEXT,"mach_msg");
 real_kevent=dlsym(RTLD_NEXT,"kevent");
 real_move=dlsym(RTLD_NEXT,"mach_port_move_member");
 real_deallocate=dlsym(RTLD_NEXT,"mach_port_deallocate");
 real_notification=dlsym(RTLD_NEXT,"mach_port_request_notification");
}
int kevent(int kq,const struct kevent *changes,int nc,struct kevent *events,int ne,const struct timespec *timeout) {
 pthread_once(&once,resolve);
 for(int i=0;i<nc;i++) op468_change(changes[i].filter,changes[i].fflags,changes[i].ext[0],changes[i].ext[1]);
 int r=real_kevent(kq,changes,nc,events,ne,timeout);
 for(int i=0;i<r;i++) {
  unsigned local=0;
  if(events[i].filter==EVFILT_MACHPORT && !(events[i].flags&EV_ERROR) && events[i].ext[0])
   local=((const mach_msg_header_t *)(uintptr_t)events[i].ext[0])->msgh_local_port;
  op468_event(events[i].filter,events[i].flags,events[i].ident,events[i].data,local);
 }
 return r;
}
kern_return_t mach_port_move_member(mach_port_t task,mach_port_t p,mach_port_t set) {
 pthread_once(&once,resolve);op468_move(p);kern_return_t kr=real_move(task,p,set);op468_registered(p,set,kr);return kr;
}
kern_return_t mach_port_deallocate(mach_port_t task,mach_port_t p) {
 pthread_once(&once,resolve);op468_deallocate(p);return real_deallocate(task,p);
}
kern_return_t mach_port_request_notification(mach_port_t task,mach_port_t p,mach_msg_id_t id,mach_port_mscount_t sync,mach_port_t notify,mach_msg_type_name_t type,mach_port_t *previous) {
 pthread_once(&once,resolve);op468_notification(task,p,notify);
 kern_return_t kr=real_notification(task,p,id,sync,notify,type,previous);
 op478_previous(p,notify,kr==KERN_SUCCESS && previous ? *previous : MACH_PORT_NULL,kr);
 op468_registered(p,notify,kr);return kr;
}

mach_msg_return_t mach_msg(mach_msg_header_t *h,mach_msg_option_t opts,mach_msg_size_t send_size,mach_msg_size_t recv_size,mach_port_name_t name,mach_msg_timeout_t timeout,mach_port_name_t notify) {
 pthread_once(&once,resolve);mach_msg_return_t kr=real_msg(h,opts,send_size,recv_size,name,timeout,notify);
 op468_received(opts,name,timeout,kr);return op478_receive(h,opts,kr);
}
