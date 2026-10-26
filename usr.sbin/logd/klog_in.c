/*
 * Copyright (c) 2004-2011 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include <TargetConditionals.h>

#if TARGET_IPHONE_SIMULATOR
struct _not_empty;
#else

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include "daemon.h"

#define forever for(;;)

#define MY_ID "klog_in"
#include "asl_input.h"

static struct asl_klog_state input_state;
static int kfd = -1;
static dispatch_source_t in_src;
static dispatch_queue_t in_queue;

static void
klog_emit(const char *line, size_t length, void *ctx __unused)
{
	asl_msg_t *m = asl_input_parse(line, (int)length, NULL, SOURCE_KERN);
	process_message(m, SOURCE_KERN);
}

void
klog_in_acceptdata(int fd)
{
	(void)asl_klog_read(fd, &input_state, klog_emit, NULL);
}

int
klog_in_init()
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		in_queue = dispatch_queue_create(MY_ID, NULL);
	});

	logdebug("%s: init\n", MY_ID);
	if (kfd >= 0) return 0;

	kfd = global.kernel_path ? open(global.kernel_path, O_RDWR | O_NONBLOCK | O_NOFOLLOW) : open(_PATH_KLOG, O_RDONLY, 0);
	if (kfd < 0)
	{
		logdebug("%s: couldn't open %s: %s\n", MY_ID, _PATH_KLOG, strerror(errno));
		return -1;
	}

	if (fcntl(kfd, F_SETFL, O_NONBLOCK) < 0)
	{
		close(kfd);
		kfd = -1;
		logdebug("%s: couldn't set O_NONBLOCK for fd %d (%s): %s\n", MY_ID, kfd, _PATH_KLOG, strerror(errno));
		return -1;
	}

	in_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)kfd, 0, in_queue);
	dispatch_source_set_event_handler(in_src, ^{ klog_in_acceptdata(kfd); });

	dispatch_resume(in_src);
	return 0;
}

int
klog_in_close(void)
{
	if (kfd < 0) return 1;

	dispatch_source_cancel(in_src);
	dispatch_release(in_src);
	in_src = NULL;

	close(kfd);
	kfd = -1;

	return 0;
}

int
klog_in_reset(void)
{
	return 0;
}

#endif /* !TARGET_IPHONE_SIMULATOR */
