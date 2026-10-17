/* SPDX-License-Identifier: BSD-2-Clause */
#ifndef NOTIFYD_MACH_OWNERSHIP_H
#define NOTIFYD_MACH_OWNERSHIP_H

#include <mach/mach.h>

void notifyd_mach_receive_error(mach_msg_return_t, mach_msg_header_t *);
void notifyd_mach_send_result(mach_msg_return_t, mach_msg_header_t *);

#endif
