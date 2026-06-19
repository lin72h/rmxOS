/* Build-only declarations for imported notifyd. */
#ifndef RMX_NOTIFYD_BUILD_COMPAT_H
#define RMX_NOTIFYD_BUILD_COMPAT_H

#include <mach/mach_types.h>
#include <mach/vm_types.h>

kern_return_t vm_deallocate(mach_port_name_t target, vm_address_t addr,
    vm_size_t size);

#endif
