/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The rmxOS project
 */

#include <stdint.h>

#include <libsys.h>

int
__proc_info(int callnum, int pid, int flavor, uint64_t arg, void *buffer,
    int buffersize)
{
	return (__sys___proc_info(callnum, pid, flavor, arg, buffer,
	    buffersize));
}

int
__iopolicysys(int cmd, struct _iopol_param_t *param)
{
	return (__sys___iopolicysys(cmd, param));
}

int
thread_switch(uint32_t thread_name, int option, uint32_t option_time)
{
	return (__sys_thread_switch(thread_name, option, option_time));
}

int
task_name_for_pid(uint32_t target_tport, int pid, uint32_t *tn)
{
	return (__sys_task_name_for_pid(target_tport, pid, tn));
}

int
task_for_pid(uint32_t target_tport, int pid, uint32_t *t)
{
	return (__sys_task_for_pid(target_tport, pid, t));
}

int
pid_for_task(uint32_t t, int *pid)
{
	return (__sys_pid_for_task(t, pid));
}
