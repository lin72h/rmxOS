/* SPDX-License-Identifier: BSD-2-Clause */
#include "mach_ownership.h"

void
notifyd_mach_receive_error(mach_msg_return_t status, mach_msg_header_t *message)
{

	/* The kernel hands acquired body resources over even on partial copyout. */
	if ((status & ~MACH_MSG_MASK) == MACH_RCV_BODY_ERROR)
		mach_msg_destroy(message);
}

void
notifyd_mach_send_result(mach_msg_return_t status, mach_msg_header_t *message)
{

	switch (status & ~MACH_MSG_MASK) {
	case MACH_SEND_INVALID_DEST:
	case MACH_SEND_TIMED_OUT:
	case MACH_SEND_INTERRUPTED:
		/* Unsent or pseudo-received: the sender owns the returned body. */
		mach_msg_destroy(message);
		break;
	default:
		break;
	}
}
