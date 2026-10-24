/* ABI constants only: Zig's C importer cannot lay out struct proc's x86 bitfields. */
#ifndef ASLD_STOP_ABI_H
#define ASLD_STOP_ABI_H
#include <stddef.h>
#include <sys/types.h>
#include <sys/user.h>
enum {
	ASLD_KINFO_SIZE = sizeof(struct kinfo_proc),
	ASLD_KINFO_PID = offsetof(struct kinfo_proc, ki_pid),
	ASLD_KINFO_STAT = offsetof(struct kinfo_proc, ki_stat)
};
#endif
