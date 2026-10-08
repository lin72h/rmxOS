/* SPDX-License-Identifier: BSD-2-Clause */
/* C ABI projection and module/sysctl routing only; probe logic is in Zig. */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/linker.h>
#include <sys/malloc.h>
#include <sys/sysctl.h>
#include <sys/mach/mach_types.h>
#include <sys/mach/ipc/ipc_entry.h>
#include <sys/mach/ipc/ipc_object.h>
#include <sys/mach/ipc/ipc_space.h>
#include <sys/mach/ipc/ipc_kmsg.h>
#include <sys/mach/ipc/ipc_port.h>
#include <sys/mach/thread.h>
#include <sys/mach/task.h>
#include <sys/proc_info.h>
#include <sys/file.h>
#include <sys/capsicum.h>
#include <sys/rwlock.h>
#include <sys/time.h>
#include <vm/vm.h>
#include <vm/vm_map.h>
/* Observe the attachment ABI common to both images, without a new symbol. */
#undef current_space
#define current_space() current_task()->itk_space
/* Project the function-like kernel-space macros through the C ABI. */
void *rmx_fixture_alloc_kernel(void);
void rmx_fixture_dealloc_kernel(void *);
void *rmx_fixture_alloc_kernel(void) { return (ipc_port_alloc_kernel()); }
void rmx_fixture_dealloc_kernel(void *p) { ipc_port_dealloc_kernel(p); }
extern kern_return_t mach_port_get_refs(ipc_space_t, mach_port_name_t,
    mach_port_right_t, mach_port_urefs_t *);

struct observation { int result; int owned; };
static int map_size_sysctl(SYSCTL_HANDLER_ARGS) {
    vm_map_t map = current_map();
    uint64_t size;
    vm_map_lock_read(map);
    size = map->size;
    vm_map_unlock_read(map);
    return (SYSCTL_OUT(req, &size, sizeof(size)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_map_size,
    CTLTYPE_U64 | CTLFLAG_RD | CTLFLAG_MPSAFE, NULL, 0,
    map_size_sysctl, "QU", "Current task mapped byte count");
struct clock_pointer { int result; uint32_t sec; int nsec; uint64_t guard; };
extern void rmx_clock_pointer_observe(struct clock_pointer *);
static int clock_pointer_sysctl(SYSCTL_HANDLER_ARGS) {
    struct clock_pointer observed;
    rmx_clock_pointer_observe(&observed);
    return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_clock_pointer,
    CTLTYPE_OPAQUE | CTLFLAG_RD | CTLFLAG_MPSAFE, NULL, 0,
    clock_pointer_sysctl, "S,clock_pointer", "Clock MIG kernel reply field");
extern int rmx_lifetime_observe(uint32_t, struct observation *);
extern void rmx_lifetime_clear(void);
void *rmx_fixture_task(void);
void *rmx_fixture_control_port(int);
int rmx_fixture_port_active(void *);
uint32_t rmx_fixture_send_count(void *);
void rmx_fixture_port_hold(void *);
void rmx_fixture_port_drop(void *);
void rmx_fixture_port_hold(void *port) { ip_reference((ipc_port_t)port); }
void rmx_fixture_port_drop(void *port) { ip_release((ipc_port_t)port); }
void *rmx_fixture_task(void) { return (current_task()); }
void *rmx_fixture_bootstrap(void);
void *rmx_fixture_bootstrap(void) { return (current_task()->itk_bootstrap); }
void *rmx_fixture_control_port(int thread) {
	return (thread ? current_thread()->ith_self : current_task()->itk_self);
}
int rmx_fixture_port_active(void *pointer) {
	ipc_port_t port = pointer;
	int active;
	ip_lock(port);
	active = ip_active(port);
	ip_unlock(port);
	return (active);
}
uint32_t rmx_fixture_send_count(void *pointer) {
	ipc_port_t port = pointer;
	uint32_t count;
	ip_lock(port);
	count = port->ip_srights;
	ip_unlock(port);
	return (count);
}
struct identity_observation { uint32_t sender[2]; uint32_t audit[8]; };
extern int rmx_identity_observe(uint64_t, struct identity_observation *);
void *rmx_fixture_message_trailer(void *);
void *rmx_fixture_message_trailer(void *message) {
	ipc_kmsg_t kmsg = message;
	return ((char *)kmsg->ikm_header + kmsg->ikm_header->msgh_size);
}
void *rmx_fixture_malloc_type(void);
void *rmx_fixture_malloc_type(void) { return (M_TEMP); }
extern int rmx_translate_observe(uint32_t, struct observation *);
extern int rmx_proc_observe(uint32_t, struct observation *);
extern int rmx_timeout_observe(uint32_t, struct observation *);
extern int rmx_urefs_observe(uint32_t, struct observation *);
struct entry_control { uint32_t name; uint64_t flags; };
extern int rmx_entry_lock_observe(const struct entry_control *, struct observation *);
void rmx_fixture_space_lock(void *);
void rmx_fixture_space_unlock(void *);
int64_t rmx_fixture_uptime(void);
void rmx_fixture_space_lock(void *space) { is_read_lock((ipc_space_t)space); }
void rmx_fixture_space_unlock(void *space) { is_read_unlock((ipc_space_t)space); }
int64_t rmx_fixture_uptime(void) { return (sbinuptime()); }
int rmx_fixture_file_hold(uint32_t, void **);
void rmx_fixture_file_drop(void *);
int rmx_fixture_get_urefs(uint32_t, uint32_t *);
int rmx_fixture_file_hold(uint32_t name, void **out) {
	cap_rights_t rights;
	return (fget(curthread, name, cap_rights_init(&rights),
	    (struct file **)out));
}
void rmx_fixture_file_drop(void *fp) { fdrop(fp, curthread); }
int rmx_fixture_get_urefs(uint32_t name, uint32_t *out) {
	return (mach_port_get_refs(current_space(), name,
	    MACH_PORT_RIGHT_DEAD_NAME, out));
}
void *rmx_fixture_thread(void);
uint32_t rmx_fixture_timeout(void *);
void rmx_fixture_set_timeout(void *, uint32_t);
void *rmx_fixture_thread(void) { return (current_thread()); }
uint32_t rmx_fixture_timeout(void *t) { return (((thread_t)t)->timeout); }
void rmx_fixture_set_timeout(void *t, uint32_t value) { ((thread_t)t)->timeout = value; }
size_t rmx_fixture_proc_size(void);
size_t rmx_fixture_bsdinfo_size(void);
void rmx_fixture_proc_copy(void *);
void rmx_fixture_proc_set_fd(void *, void *);
void rmx_fixture_proc_set_group(void *, void *);
int rmx_fixture_nfiles(void *);
void *rmx_fixture_space(void);
void *rmx_fixture_entry(uint32_t);
void *rmx_fixture_entry_locked(uint32_t);
void *rmx_fixture_object(void *);
int rmx_fixture_owned(void *);
void rmx_fixture_unlock(void *);
void *rmx_fixture_space(void) { return (current_space()); }
void *rmx_fixture_entry_locked(uint32_t name) {
	return (ipc_entry_lookup(current_space(), name));
}
void *rmx_fixture_entry(uint32_t name) {
	ipc_entry_t entry;
	is_read_lock(current_space());
	entry = ipc_entry_lookup(current_space(), name);
	if (entry == IE_NULL)
		is_read_unlock(current_space());
	return (entry);
}
void *rmx_fixture_object(void *entry) {
	ipc_object_t object = ((ipc_entry_t)entry)->ie_object;
	is_read_unlock(current_space());
	return (object);
}
int rmx_fixture_owned(void *object) { return (io_lock_owned(object)); }
void rmx_fixture_unlock(void *object) { io_unlock(object); }
size_t rmx_fixture_proc_size(void) { return (sizeof(struct proc)); }
size_t rmx_fixture_bsdinfo_size(void) { return (sizeof(struct proc_bsdinfo)); }
void rmx_fixture_proc_copy(void *p) { bcopy(curproc, p, sizeof(struct proc)); }
void rmx_fixture_proc_set_fd(void *p, void *fd) { ((struct proc *)p)->p_fd = fd; }
void rmx_fixture_proc_set_group(void *p, void *pg) { ((struct proc *)p)->p_pgrp = pg; }
int rmx_fixture_nfiles(void *info) { return (((struct proc_bsdinfo *)info)->pbi_nfiles); }

static int
observe_sysctl(SYSCTL_HANDLER_ARGS)
{
	uint32_t name;
	struct observation observed;
	int error;
	error = SYSCTL_IN(req, &name, sizeof(name));
	if (error != 0)
		return (error);
 error = ((int (*)(uint32_t, struct observation *))arg1)(name, &observed);
	if (error != 0)
		return (error);
	return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_translate_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_translate_observe, 0, observe_sysctl,
    "S,observation", "Mach translation lock observation for ATF");
SYSCTL_PROC(_debug, OID_AUTO, rmx_lifetime_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_lifetime_observe, 0,
    observe_sysctl, "S,observation", "Mach lifetime observation for ATF");
SYSCTL_PROC(_debug, OID_AUTO, rmx_proc_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_proc_observe, 0, observe_sysctl,
    "S,observation", "Mach BSD proc observation for ATF");
SYSCTL_PROC(_debug, OID_AUTO, rmx_timeout_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_timeout_observe, 0, observe_sysctl,
    "S,observation", "Mach timeout tick observation for ATF");
SYSCTL_PROC(_debug, OID_AUTO, rmx_urefs_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_urefs_observe, 0, observe_sysctl,
    "S,observation", "Mach urefs with a transient native file hold");
static int
entry_lock_sysctl(SYSCTL_HANDLER_ARGS)
{
	struct entry_control control;
	struct observation observed;
	int error;

	error = SYSCTL_IN(req, &control, sizeof(control));
	if (error == 0)
		error = rmx_entry_lock_observe(&control, &observed);
	if (error != 0)
		return (error);
	return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_entry_lock_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, entry_lock_sysctl,
    "S,observation", "Descriptor removal while an entry lookup holds its space");
static int
identity_sysctl(SYSCTL_HANDLER_ARGS)
{
	uint64_t address;
	struct identity_observation observed;
	int error;

	error = SYSCTL_IN(req, &address, sizeof(address));
	if (error == 0)
		error = rmx_identity_observe(address, &observed);
	if (error != 0)
		return (error);
	return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_identity_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE | CTLFLAG_ANYBODY,
    NULL, 0, identity_sysctl,
    "S,identity_observation", "Identity in the constructed Mach send trailer");
static int module_event(module_t mod __unused, int event, void *arg __unused)
{
	if (event == MOD_UNLOAD)
		rmx_lifetime_clear();
	return (event == MOD_LOAD || event == MOD_UNLOAD ? 0 : EOPNOTSUPP);
}
static moduledata_t module = { "rmx_translate_fixture", module_event, NULL };
DECLARE_MODULE(rmx_translate_fixture, module, SI_SUB_DRIVERS, SI_ORDER_ANY);
MODULE_DEPEND(rmx_translate_fixture, mach, 1, 1, 1);

/* Route the real process constructor/destructor events for an unpublished
 * proc snapshot with an empty thread list, as at first thread_alloc failure. */
void rmx_fixture_proc_empty(void *);
void rmx_fixture_proc_ctor(void *);
void rmx_fixture_proc_dtor(void *);
int rmx_fixture_proc_attached(void *);
void rmx_fixture_proc_empty(void *p) { TAILQ_INIT(&((struct proc *)p)->p_threads); }
void rmx_fixture_proc_ctor(void *p) { EVENTHANDLER_DIRECT_INVOKE(process_ctor, p); }
void rmx_fixture_proc_dtor(void *p) { EVENTHANDLER_DIRECT_INVOKE(process_dtor, p); }
int rmx_fixture_proc_attached(void *p) { return (((struct proc *)p)->p_machdata != NULL); }

size_t rmx_fixture_mach_thread_size(void);
void *rmx_fixture_parked(void *);
void rmx_fixture_set_parked(void *, void *);
void *rmx_fixture_kmsg_header(void *);
size_t rmx_fixture_kmsg_header_size(void);
size_t rmx_fixture_mach_thread_size(void) { return (sizeof(*((thread_t)NULL))); }
void *rmx_fixture_parked(void *t) { return (((thread_t)t)->ith_kmsg); }
void rmx_fixture_set_parked(void *t, void *m) { ((thread_t)t)->ith_kmsg = m; }
void *rmx_fixture_kmsg_header(void *m) { return (((ipc_kmsg_t)m)->ikm_header); }
size_t rmx_fixture_kmsg_header_size(void) { return (sizeof(mach_msg_header_t)); }

extern int rmx_lifetime_refs(uint32_t, struct observation *);
SYSCTL_PROC(_debug, OID_AUTO, rmx_lifetime_refs,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_lifetime_refs, 0,
    observe_sysctl, "S,observation", "Mach namespace urefs without a native file hold");
void *rmx_fixture_first_file(void *);
void rmx_fixture_file_revoke(void *);
void *rmx_fixture_first_file(void *pointer) {
	ipc_space_t space = pointer;
	ipc_entry_t entry;
	struct file *fp = NULL;
	is_read_lock(space);
	entry = LIST_FIRST(&space->is_entry_list);
	if (entry != IE_NULL) {
		fp = entry->ie_fp;
		(void)fhold(fp);
	}
	is_read_unlock(space);
	return (fp);
}
void rmx_fixture_file_revoke(void *pointer) {
	struct file *fp = pointer;
	fp->f_ops->fo_fdclose(fp, 0, curthread);
	fp->f_ops->fo_fdpostclose(fp, 0, curthread);
}

/* Native ABI projections for the controlled pset notification interlock. */
#include <sys/mach/ipc/ipc_pset.h>
#include <sys/mach/ipc/ipc_right.h>
#include <sys/sx.h>
void *rmx_fixture_pset_hold(uint32_t);
void rmx_fixture_pset_drop(void *);
void rmx_fixture_note_lock(void *);
void rmx_fixture_note_unlock(void *);
int rmx_fixture_note_waiter(void *);
uint32_t rmx_fixture_pset_refs(void *);
void rmx_fixture_pause(void);
void *rmx_fixture_pset_hold(uint32_t name) {
 ipc_object_t object;
 if (ipc_object_translate(current_space(), name, MACH_PORT_RIGHT_PORT_SET,
     &object) != KERN_SUCCESS) return (NULL);
 io_reference(object); io_unlock(object); return (object);
}
void rmx_fixture_pset_drop(void *p) { ips_release((ipc_pset_t)p); }
void rmx_fixture_note_lock(void *p) { sx_xlock(&((ipc_pset_t)p)->ips_note_lock); }
void rmx_fixture_note_unlock(void *p) { sx_xunlock(&((ipc_pset_t)p)->ips_note_lock); }
int rmx_fixture_note_waiter(void *p) {
 return ((atomic_load_acq_ptr(&((ipc_pset_t)p)->ips_note_lock.sx_lock) &
     (SX_LOCK_SHARED_WAITERS | SX_LOCK_EXCLUSIVE_WAITERS)) != 0);
}
uint32_t rmx_fixture_pset_refs(void *p) {
 return (atomic_load_acq_int(&((ipc_pset_t)p)->ips_object.io_references));
}
void rmx_fixture_pause(void) { pause("rmxfixture", 1); }
extern int rmx_pset_pin_observe(uint64_t, struct observation *);
static int pset_pin_sysctl(SYSCTL_HANDLER_ARGS) {
 uint64_t command; struct observation observed; int error;
 error = SYSCTL_IN(req, &command, sizeof(command));
 if (error == 0) error = rmx_pset_pin_observe(command, &observed);
 if (error != 0) return (error);
 return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_pset_pin_observe,
 CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, pset_pin_sysctl,
 "S,observation", "Pset notification pin at its native sx interlock");
/* ABI projection only; copyout scheduling and assertions live in Zig. */
extern int rmx_copyout_observe(uint64_t, struct observation *);
static int copyout_sysctl(SYSCTL_HANDLER_ARGS) {
 uint64_t command; struct observation observed; int error;
 error = SYSCTL_IN(req, &command, sizeof(command));
 if (error == 0) error = rmx_copyout_observe(command, &observed);
 if (error != 0) return (error);
 return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_copyout_observe,
 CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, copyout_sysctl,
 "S,observation", "Concurrent first send-right copyouts");
void *rmx_fixture_receive_hold(uint32_t);
void rmx_fixture_object_lock(void *);
void rmx_fixture_object_drop(void *);
int rmx_fixture_retire_waiter(void *, void *);
uint32_t rmx_fixture_object_refs(void *);
void *rmx_fixture_receive_hold(uint32_t name) {
 ipc_object_t object;
 if (ipc_object_translate(current_space(), name, MACH_PORT_RIGHT_RECEIVE,
     &object) != KERN_SUCCESS) return (NULL);
 io_reference(object); io_unlock(object); return (object);
}
void rmx_fixture_object_lock(void *p) { io_lock((ipc_object_t)p); }
void rmx_fixture_object_drop(void *p) { io_release((ipc_object_t)p); }
int rmx_fixture_retire_waiter(void *set, void *port) {
 int retiring;
 (void)port;
 if (!ips_lock_try((ipc_pset_t)set)) return (0);
 retiring = !io_active((ipc_object_t)set);
 ips_unlock((ipc_pset_t)set);
 return (retiring);
}
uint32_t rmx_fixture_object_refs(void *p) { return (atomic_load_acq_int(&((ipc_object_t)p)->io_references)); }
/* op461: project real fileops phases and admitted wait enrollment. */
#include <sys/mach/ipc/ipc_mqueue.h>
struct revocation_state {
 struct file *fp;
 ipc_entry_t entry;
 ipc_object_t object;
 ipc_port_t member, carried;
 struct thread *receiver;
};
static struct revocation_state revoke_state;
int rmx_revoke_prepare(uint32_t name, uint32_t member);
void rmx_revoke_thread(void);
void rmx_revoke_thread_done(void);
void rmx_revoke_facts(uint32_t *);
void rmx_revoke_phase(int);
int rmx_revoke_deliver(void);
void rmx_revoke_finish(void);
int rmx_revoke_prepare(uint32_t name, uint32_t member) {
 struct revocation_state *s = &revoke_state;
 cap_rights_t rights;
 int error = fget(curthread, name, cap_rights_init(&rights), &s->fp);
 if (error) return (error);
 s->entry = s->fp->f_data;
 is_read_lock(s->entry->ie_space);
 s->object = s->entry->ie_object;
 ipc_entry_reference(s->entry); io_reference(s->object);
 is_read_unlock(s->entry->ie_space);
 s->member = rmx_fixture_receive_hold(member);
 s->carried = ipc_port_alloc_kernel();
 s->receiver = NULL;
 return (s->member && s->carried ? 0 : EINVAL);
}
void rmx_revoke_thread(void) { revoke_state.receiver = curthread; }
void rmx_revoke_thread_done(void) { revoke_state.receiver = NULL; }
void rmx_revoke_facts(uint32_t *out) {
 struct revocation_state *s = &revoke_state;
 struct thread *td = s->receiver;
 out[0] = 0;
 if (td) { thread_lock(td); out[0] = td->td_wchan == s->object; thread_unlock(td); }
 is_read_lock(s->entry->ie_space);
 out[1] = s->entry->ie_revoked;
 out[2] = s->entry->ie_references;
 is_read_unlock(s->entry->ie_space);
 io_lock(s->object); out[3] = s->object->io_references; io_unlock(s->object);
 ip_lock(s->member); out[4] = s->member->ip_msgcount; ip_unlock(s->member);
 ip_lock(s->carried); out[5] = s->carried->ip_srights; ip_unlock(s->carried);
}
void rmx_revoke_phase(int post) {
 struct file *fp = revoke_state.fp;
 if (post) fp->f_ops->fo_fdpostclose(fp, -1, curthread);
 else fp->f_ops->fo_fdclose(fp, -1, curthread);
}
int rmx_revoke_deliver(void) {
 struct revocation_state *s = &revoke_state;
 struct { mach_msg_header_t head; mach_msg_body_t body; mach_msg_port_descriptor_t right; } message = {0};
 ipc_kmsg_t kmsg;
 mach_msg_return_t mr;
 message.head.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_PORT_SEND,0);
 message.head.msgh_size = sizeof(message);
 message.head.msgh_remote_port = (mach_port_t)ipc_port_make_send(s->member);
 message.head.msgh_id = 46101;
 message.body.msgh_descriptor_count = 1;
 message.right.name = (mach_port_t)ipc_port_make_send(s->carried);
 message.right.disposition = MACH_MSG_TYPE_PORT_SEND;
 message.right.type = MACH_MSG_PORT_DESCRIPTOR;
 mr = ipc_kmsg_get_from_kernel(&message.head, sizeof(message), &kmsg);
 if (mr != MACH_MSG_SUCCESS) return (mr);
 return (ipc_mqueue_send(kmsg, MACH_SEND_ALWAYS, 0));
}
void rmx_revoke_finish(void) {
 struct revocation_state *s = &revoke_state;
 ipc_entry_put(s->entry); ipc_object_release(s->object);
 ip_release(s->member); ipc_port_dealloc_kernel(s->carried);
 fdrop(s->fp,curthread); bzero(s,sizeof(*s));
}
extern int rmx_revoke_control(uint64_t, uint32_t *);
static int revoke_sysctl(SYSCTL_HANDLER_ARGS) {
 uint64_t command; uint32_t out[8] = {0}; int error;
 error=SYSCTL_IN(req,&command,sizeof(command));
 if (!error) error=rmx_revoke_control(command,out);
 if (error) return (error);
 return (SYSCTL_OUT(req,out,sizeof(out)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_revoke_control, CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE,
 NULL,0,revoke_sysctl,"S,revocation","Admitted receive entry revocation before postclose");
/* MIG table ABI projection: temporarily replace a known task-family routine. */
#include <sys/mach/mig_errors.h>
struct fixture_mig_hash { mach_msg_id_t num; mig_routine_t routine; int size;
#if MACH_COUNTERS
 mach_counter_t callcount;
#endif
};
extern struct fixture_mig_hash mig_buckets[1024];
extern void rmx_poison_reply(mach_msg_header_t *, mach_msg_header_t *);
int rmx_mig_slot_num(uint32_t);
void rmx_mig_slot_set(uint32_t, uint32_t);
void *rmx_mig_trailer(void *);
uint32_t rmx_mig_trailer_size(void);
void rmx_mig_success(void *);
int rmx_mig_slot_num(uint32_t i) { return (mig_buckets[i].num); }
static struct fixture_mig_hash saved_mig_slot;
void rmx_mig_slot_set(uint32_t i, uint32_t id) {
 if (id) {
  saved_mig_slot = mig_buckets[i];
  mig_buckets[i].routine = rmx_poison_reply;
  mig_buckets[i].size = sizeof(mig_reply_error_t);
 } else {
  mig_buckets[i] = saved_mig_slot;
 }
}
void *rmx_mig_trailer(void *p) { mach_msg_header_t *m=p; return ((char *)p+round_msg(m->msgh_size)); }
uint32_t rmx_mig_trailer_size(void) { return (MAX_TRAILER_SIZE); }
void rmx_mig_success(void *p) { ((mig_reply_error_t *)p)->RetCode = KERN_SUCCESS; }
extern int rmx_mig_control(uint32_t, uint32_t *);
static int mig_control_sysctl(SYSCTL_HANDLER_ARGS) {
 uint32_t input,out=0; int error=SYSCTL_IN(req,&input,sizeof(input));
 if (!error) error=rmx_mig_control(input,&out);
 if (error) return (error);return (SYSCTL_OUT(req,&out,sizeof(out)));
}
SYSCTL_PROC(_debug,OID_AUTO,rmx_mig_control,CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE,
 NULL,0,mig_control_sysctl,"I","Poison a real MIG routine reply before producer trailer initialization");

extern int rmx_child_send_count(uint32_t, struct observation *);
SYSCTL_PROC(_debug, OID_AUTO, rmx_child_send_count,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, rmx_child_send_count, 0,
    observe_sysctl, "S,observation", "Mach send-right count for refusal ownership tests");

/* Field projection only: the Zig observer owns iteration and result records. */
struct child_action { uint32_t present; int behavior; int flavor; };
void rmx_fixture_child_action(uint32_t, struct child_action *);
void rmx_fixture_child_action(uint32_t index, struct child_action *out) {
    task_t task = current_task();
    itk_lock(task);
    out->present = IP_VALID(task->exc_actions[index].port);
    out->behavior = task->exc_actions[index].behavior;
    out->flavor = task->exc_actions[index].flavor;
    itk_unlock(task);
}
extern int rmx_child_crash(uint32_t, struct child_action *);
static int child_crash_sysctl(SYSCTL_HANDLER_ARGS) {
    uint32_t index = 0;
    struct child_action observed = {0};
    int error = SYSCTL_IN(req, &index, sizeof(index));
    if (error == 0) error = rmx_child_crash(index, &observed);
    if (error == 0) error = SYSCTL_OUT(req, &observed, sizeof(observed));
    return (error);
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_child_crash,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_MPSAFE, NULL, 0,
    child_crash_sysctl, "S,child_action", "Stored task exception action projection");
