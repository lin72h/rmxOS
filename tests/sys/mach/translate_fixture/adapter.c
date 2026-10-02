/* SPDX-License-Identifier: BSD-2-Clause */
/* C ABI projection and module/sysctl routing only; probe logic is in Zig. */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/malloc.h>
#include <sys/sysctl.h>
#include <sys/mach/mach_types.h>
#include <sys/mach/ipc/ipc_entry.h>
#include <sys/mach/ipc/ipc_object.h>
#include <sys/mach/ipc/ipc_space.h>
#include <sys/mach/ipc/ipc_kmsg.h>
#include <sys/mach/ipc/ipc_port.h>
#include <sys/mach/thread.h>
#include <sys/proc_info.h>
#include <sys/file.h>
#include <sys/capsicum.h>
#include <sys/rwlock.h>
#include <sys/time.h>
extern kern_return_t mach_port_get_refs(ipc_space_t, mach_port_name_t,
    mach_port_right_t, mach_port_urefs_t *);

struct observation { int result; int owned; };
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
static int module_event(module_t mod __unused, int event, void *arg __unused)
{
	return (event == MOD_LOAD || event == MOD_UNLOAD ? 0 : EOPNOTSUPP);
}
static moduledata_t module = { "rmx_translate_fixture", module_event, NULL };
DECLARE_MODULE(rmx_translate_fixture, module, SI_SUB_DRIVERS, SI_ORDER_ANY);
MODULE_DEPEND(rmx_translate_fixture, mach, 1, 1, 1);
