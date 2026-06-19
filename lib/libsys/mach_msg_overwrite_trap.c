/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The rmxOS project
 */

#include <sys/mach/message.h>

#include <libsys.h>

struct mach_msg_overwrite_tail {
	mach_msg_header_t *rcv_msg;
	mach_msg_size_t scatter_list_size;
};

mach_msg_return_t
mach_msg_overwrite_trap(mach_msg_header_t *msg, mach_msg_option_t option,
    mach_msg_size_t send_size, mach_msg_size_t rcv_size,
    mach_port_name_t rcv_name, mach_msg_timeout_t timeout,
    mach_port_name_t notify, mach_msg_header_t *rcv_msg,
    mach_msg_size_t scatter_list_size)
{
	struct mach_msg_overwrite_tail tail;

	tail.rcv_msg = rcv_msg;
	tail.scatter_list_size = scatter_list_size;
	return (__sys_mach_msg_overwrite_trap(msg, option, send_size,
	    rcv_size, rcv_name, timeout, notify, &tail));
}
