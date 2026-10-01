/*-
 * Copyright (c) 2014 Matthew Macy <mmacy@netxbsd.org>
 * Copyright (c) 2002-2003 The NetBSD Foundation, Inc.
 * All rights reserved.
 *
 * This code is derived from software contributed to The NetBSD Foundation
 * by Emmanuel Dreyfus
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE NETBSD FOUNDATION, INC. AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <sys/cdefs.h>
__FBSDID("$FreeBSD$");

#include <sys/types.h>
#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/systm.h>
#include <sys/signal.h>
#include <sys/proc.h>
#include <sys/time.h>

#include <sys/mach/mach_types.h>
#include <sys/mach/message.h>
#include <sys/mach/mach.h>
#include <sys/mach/ipc/ipc_mqueue.h>
#include <sys/mach/thread.h>

#include <sys/mach/clock_types.h>
#include <sys/mach/clock_server.h>

kern_return_t
clock_sleep(mach_port_name_t clock_name, mach_sleep_type_t type, int sleep_sec,
    int sleep_nsec, mach_timespec_t *wakeup_time)
{
	struct timespec now;
	mach_timespec_t wake;
	sbintime_t deadline, uptime;
	int error, channel = 0;

	/* Only the system uptime clock is supported by this trap. */
	if (clock_name != 0 || (type != TIME_ABSOLUTE && type != TIME_RELATIVE) ||
	    sleep_sec < 0 || sleep_nsec < 0 || sleep_nsec >= 1000000000)
		return (KERN_INVALID_ARGUMENT);
	deadline = (sbintime_t)sleep_sec * SBT_1S + nstosbt(sleep_nsec);
	uptime = sbinuptime();
	if (type == TIME_RELATIVE) {
		if (deadline > SBT_MAX - uptime)
			return (KERN_INVALID_ARGUMENT);
		deadline += uptime;
	}
	/* A private channel cannot be awakened by Mach thread_go(). */
	if (deadline > uptime) {
		error = msleep_sbt(&channel, (struct mtx *)NULL, PCATCH | PSOCK, "mach_clock",
		    deadline, 0, C_ABSOLUTE);
		if (error == EINTR || error == ERESTART)
			return (KERN_ABORTED);
		if (error != EWOULDBLOCK && error != 0)
			return (KERN_FAILURE);
	}
	if (wakeup_time != NULL) {
		nanouptime(&now);
		wake.tv_sec = now.tv_sec;
		wake.tv_nsec = now.tv_nsec;
		if (copyout(&wake, wakeup_time, sizeof(wake)) != 0)
			return (KERN_INVALID_ADDRESS);
	}
	return (KERN_SUCCESS);
}

int
mach_timebase_info(mach_timebase_info_t infop)
{
	/* {
		syscallarg(mach_timebase_info_t) info;
	} */
	int error;
	struct mach_timebase_info info;

	/* XXX This is probably bus speed, fill it accurately */
	info.numer = 4000000000UL;
	info.denom = 75189611UL;

	if ((error = copyout(&info, (void *)infop,
	    sizeof(info))) != 0)
		return (error);

	return (0);
}

int
clock_get_time(clock_serv_t clock_serv, mach_timespec_t *cur_time)
{
	struct timespec ts;

	nanotime(&ts);

	return (copyout(&ts, cur_time, sizeof(ts)));
}

int
clock_get_attributes(
	clock_serv_t clock_serv,
	clock_flavor_t flavor,
	clock_attr_t clock_attr,
	mach_msg_type_number_t *clock_attrCnt
)
UNSUPPORTED;

int
clock_alarm(
	clock_serv_t clock_serv,
	alarm_type_t alarm_type,
	mach_timespec_t alarm_time,
	clock_reply_t alarm_port,
	mach_msg_type_name_t alarm_portPoly
)
UNSUPPORTED;	
