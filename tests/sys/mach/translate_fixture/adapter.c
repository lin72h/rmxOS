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

