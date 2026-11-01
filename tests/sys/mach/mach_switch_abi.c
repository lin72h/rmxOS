/* SPDX-License-Identifier: BSD-2-Clause
 * Layout adapter only; test logic is in mach_swtch.zig.
 */
#include <sys/types.h>
#include <sys/user.h>
#include <stddef.h>
const size_t mach_kinfo_size = sizeof(struct kinfo_proc);
const size_t mach_kinfo_priority = offsetof(struct kinfo_proc, ki_pri.pri_level);
