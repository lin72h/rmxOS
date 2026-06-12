/*
 * Copyright (c) 2026 rmxOS contributors.
 *
 * Licensed under the Apache License, Version 2.0.
 */

#ifndef __DISPATCH_MACH_NOTIFY_DECODE_H__
#define __DISPATCH_MACH_NOTIFY_DECODE_H__

#include <mach/notify.h>
#include <stdbool.h>
#include <stddef.h>

static inline bool
_dispatch_mach_dead_name_decode(const mach_msg_header_t *hdr,
		mach_port_name_t *name)
{
	const mach_dead_name_notification_t *notification;

	if (!hdr || !name || hdr->msgh_id != MACH_NOTIFY_DEAD_NAME ||
			hdr->msgh_size != offsetof(mach_dead_name_notification_t, trailer)) {
		return false;
	}
	notification = (const mach_dead_name_notification_t *)hdr;
	*name = notification->not_port;
	return true;
}

#endif
