/* SPDX-License-Identifier: BSD-2-Clause */
#ifndef _COMPAT_MACH_OOL_H_
#define _COMPAT_MACH_OOL_H_

/*
 * Bytes the kernel holds for out-of-line data: vm_map_copy kernel buffers
 * and OOL port arrays, system-wide.  mach.ool_max_total bounds them all,
 * mach.ool_max_message the OOL bytes of one message.
 */
extern u_long mach_ool_max_message;

kern_return_t	mach_ool_reserve(vm_size_t len);
void		mach_ool_release(vm_size_t len);

void		ipc_kmsg_ool_ports_free(void *array, mach_msg_type_number_t count);

#endif
