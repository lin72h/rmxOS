/* SPDX-License-Identifier: BSD-2-Clause */
#ifndef _COMPAT_MACH_IPC_DEBUG_H_
#define _COMPAT_MACH_IPC_DEBUG_H_

/* Existing debug.mach controls; ordinary user errors are quiet by default. */
extern int mach_ipc_entry_lookup_failed_log;
extern int mach_ipc_right_copyin_failed_log;

#endif
