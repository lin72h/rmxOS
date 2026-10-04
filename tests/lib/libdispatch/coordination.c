/* ABI and controlled libc/libmach call interposition; Zig owns assertions. */
#include <sys/types.h>
#include <sys/event.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <errno.h>
void op468_configure(int, unsigned);
int op468_wait_copied(void);
void op468_release(void);
void op468_facts(unsigned *);
unsigned op468_copied_set(void);
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int mode, copied, released;
static mach_port_t watched, copied_set;
static _Atomic unsigned wire, moves, releases, registrations;
void op468_configure(int m, unsigned p) {
 pthread_mutex_lock(&lock); mode=m; watched=p; copied=released=0;
 atomic_store(&wire,0); atomic_store(&moves,0); atomic_store(&releases,0);
 atomic_store(&registrations,0); pthread_mutex_unlock(&lock);
}
int op468_wait_copied(void) {
 struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); ts.tv_sec+=3;
 pthread_mutex_lock(&lock); int rc=0;
 while (!copied && !rc) rc=pthread_cond_timedwait(&cv,&lock,&ts);
 pthread_mutex_unlock(&lock); return rc;
}
unsigned op468_copied_set(void) { return copied_set; }
void op468_release(void) {
 pthread_mutex_lock(&lock); released=1; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&lock);
}
void op468_facts(unsigned *out) {
 out[0]=atomic_load(&wire);out[1]=atomic_load(&moves);
 out[2]=atomic_load(&releases);out[3]=atomic_load(&registrations);
}
int kevent(int kq,const struct kevent *changes,int nc,struct kevent *events,int ne,const struct timespec *timeout) {
 static int (*real)(int,const struct kevent*,int,struct kevent*,int,const struct timespec*);
 if (!real) real=dlsym(RTLD_NEXT,"kevent");
 for(int i=0;i<nc;i++) if(changes[i].filter==EVFILT_MACHPORT && (changes[i].fflags || changes[i].ext[0] || changes[i].ext[1])) atomic_fetch_add(&wire,1);
 int r=real(kq,changes,nc,events,ne,timeout);
 pthread_mutex_lock(&lock);
 for(int i=0;i<r;i++) if(events[i].filter==EVFILT_MACHPORT && mode && !copied) {
  copied_set=events[i].ident;copied=1;pthread_cond_broadcast(&cv);
  while(!released) pthread_cond_wait(&cv,&lock);
 }
 pthread_mutex_unlock(&lock);return r;
}
kern_return_t mach_port_move_member(mach_port_t task,mach_port_t p,mach_port_t set) {
 static kern_return_t (*real)(mach_port_t,mach_port_t,mach_port_t);
 if(!real) real=dlsym(RTLD_NEXT,"mach_port_move_member");
 pthread_mutex_lock(&lock);int observe=released && p==watched;pthread_mutex_unlock(&lock);
 if(observe) atomic_fetch_add(&moves,1);
 return real(task,p,set);
}
kern_return_t mach_port_deallocate(mach_port_t task,mach_port_t p) {
 static kern_return_t (*real)(mach_port_t,mach_port_t);
 if(!real) real=dlsym(RTLD_NEXT,"mach_port_deallocate");
 if(p==watched) atomic_fetch_add(&releases,1);
 return real(task,p);
}
kern_return_t mach_port_request_notification(mach_port_t task,mach_port_t p,mach_msg_id_t id,mach_port_mscount_t sync,mach_port_t notify,mach_msg_type_name_t type,mach_port_t *previous) {
 static kern_return_t (*real)(mach_port_t,mach_port_t,mach_msg_id_t,mach_port_mscount_t,mach_port_t,mach_msg_type_name_t,mach_port_t*);
 if(!real) real=dlsym(RTLD_NEXT,"mach_port_request_notification");
 if(p==watched && notify) {
  atomic_fetch_add(&registrations,1);
  pthread_mutex_lock(&lock);int die=mode==3;mode=die?0:mode;pthread_mutex_unlock(&lock);
  if(die) mach_port_mod_refs(task,p,MACH_PORT_RIGHT_RECEIVE,-1);
 }
 return real(task,p,id,sync,notify,type,previous);
}
