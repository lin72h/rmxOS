/* ABI constants only: Zig's C importer cannot lay out struct proc's x86 bitfields. */
#ifndef LOGD_STOP_ABI_H
#define LOGD_STOP_ABI_H
#include <stddef.h>
#include <sys/types.h>
#include <sys/user.h>
enum {
	LOGD_KINFO_SIZE = sizeof(struct kinfo_proc),
	LOGD_KINFO_PID = offsetof(struct kinfo_proc, ki_pid),
	LOGD_KINFO_STAT = offsetof(struct kinfo_proc, ki_stat)
};
#endif
