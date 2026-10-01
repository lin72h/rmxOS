/* SPDX-License-Identifier: BSD-2-Clause */
/* C ABI projection and module/sysctl routing only; probe logic is in Zig. */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/sysctl.h>
#include <sys/mach/mach_types.h>
#include <sys/mach/ipc/ipc_entry.h>
#include <sys/mach/ipc/ipc_object.h>
#include <sys/mach/ipc/ipc_space.h>
#include <sys/mach/ipc/ipc_kmsg.h>
#include <sys/mach/ipc/ipc_port.h>
#include <sys/mach/thread.h>

struct observation { int result; int owned; };
extern int rmx_translate_observe(uint32_t, struct observation *);
void *rmx_fixture_space(void);
void *rmx_fixture_entry(uint32_t);
void *rmx_fixture_object(void *);
int rmx_fixture_owned(void *);
void rmx_fixture_unlock(void *);
void *rmx_fixture_space(void) { return (current_space()); }
void *rmx_fixture_entry(uint32_t name) {
	return (ipc_entry_lookup(current_space(), name));
}
void *rmx_fixture_object(void *entry) { return (((ipc_entry_t)entry)->ie_object); }
int rmx_fixture_owned(void *object) { return (io_lock_owned(object)); }
void rmx_fixture_unlock(void *object) { io_unlock(object); }

static int
observe_sysctl(SYSCTL_HANDLER_ARGS)
{
	uint32_t name;
	struct observation observed;
	int error;
	error = SYSCTL_IN(req, &name, sizeof(name));
	if (error != 0)
		return (error);
	error = rmx_translate_observe(name, &observed);
	if (error != 0)
		return (error);
	return (SYSCTL_OUT(req, &observed, sizeof(observed)));
}
SYSCTL_PROC(_debug, OID_AUTO, rmx_translate_observe,
    CTLTYPE_OPAQUE | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, observe_sysctl,
    "S,observation", "Mach translation lock observation for ATF");
static int module_event(module_t mod __unused, int event, void *arg __unused)
{
	return (event == MOD_LOAD || event == MOD_UNLOAD ? 0 : EOPNOTSUPP);
}
static moduledata_t module = { "rmx_translate_fixture", module_event, NULL };
DECLARE_MODULE(rmx_translate_fixture, module, SI_SUB_DRIVERS, SI_ORDER_ANY);
MODULE_DEPEND(rmx_translate_fixture, mach, 1, 1, 1);
