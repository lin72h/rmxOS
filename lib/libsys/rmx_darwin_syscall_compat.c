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
