/*
 * Copyright 1991-1998 by Open Software Foundation, Inc. 
 *              All Rights Reserved 
 *  
 * Permission to use, copy, modify, and distribute this software and 
 * its documentation for any purpose and without fee is hereby granted, 
 * provided that the above copyright notice appears in all copies and 
 * that both the copyright notice and this permission notice appear in 
 * supporting documentation. 
 *  
 * OSF DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE 
 * INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
 * FOR A PARTICULAR PURPOSE. 
 *  
 * IN NO EVENT SHALL OSF BE LIABLE FOR ANY SPECIAL, INDIRECT, OR 
 * CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM 
 * LOSS OF USE, DATA OR PROFITS, WHETHER IN ACTION OF CONTRACT, 
 * NEGLIGENCE, OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION 
 * WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. 
 */
/* 
 * Mach Operating System
 * Copyright (c) 1991,1990,1989 Carnegie Mellon University
 * All Rights Reserved.
 * 
 * Permission to use, copy, modify and distribute this software and its
 * documentation is hereby granted, provided that both the copyright
 * notice and this permission notice appear in all copies of the
 * software, derivative works or modified versions, and any portions
 * thereof, and that both notices appear in supporting documentation.
 * 
 * CARNEGIE MELLON ALLOWS FREE USE OF THIS SOFTWARE IN ITS "AS IS"
 * CONDITION.  CARNEGIE MELLON DISCLAIMS ANY LIABILITY OF ANY KIND FOR
 * ANY DAMAGES WHATSOEVER RESULTING FROM THE USE OF THIS SOFTWARE.
 * 
 * Carnegie Mellon requests users of this software to return to
 * 
 *  Software Distribution Coordinator  or  Software.Distribution@CS.CMU.EDU
 *  School of Computer Science
 *  Carnegie Mellon University
 *  Pittsburgh PA 15213-3890
 * 
 * any improvements or extensions that they make and grant Carnegie Mellon
 * the rights to redistribute these changes.
 */
/*
 * MkLinux
 */
/*
 *  Abstract:
 *	Routines to set and deallocate the mig reply port.
 *	They are called from mig generated interfaces.
 *
 */

#include <mach/mach.h>
#include <mach/mach_traps.h>
#include <pthread.h>
#include <stdint.h>
#include "externs.h"

static pthread_once_t mig_reply_once = PTHREAD_ONCE_INIT;
static pthread_key_t mig_reply_key;
static int mig_reply_key_error;

static void
mig_reply_destroy(void *value)
{
	/* libthr clears the key before calling its destructor.  This direct
	 * trap does not allocate a new MIG reply port while releasing this one. */
	(void)mach_port_mod_refs(mach_task_self(), (mach_port_t)(uintptr_t)value,
	    MACH_PORT_RIGHT_RECEIVE, -1);
}

static void
mig_reply_key_create(void)
{
	mig_reply_key_error = pthread_key_create(&mig_reply_key, mig_reply_destroy);
}

static int
mig_reply_key_ready(void)
{
	return (pthread_once(&mig_reply_once, mig_reply_key_create) == 0 &&
	    mig_reply_key_error == 0);
}

/*****************************************************
 *  Called by mach_init. This is necessary after
 *  a fork to get rid of bogus port number.
 ****************************************************/

void
mig_init(void * arg __unused)
{
	/* The child's task/space is new: discard the inherited thread slot,
	 * rather than trying to release a parent's name in the child's space. */
	if (mig_reply_key_ready())
		(void)pthread_setspecific(mig_reply_key, NULL);
}

/********************************************************
 *  Called by mig interfaces whenever they  need a reply port.
 *  Used to provide the same interface as multi-threaded tasks need.
 ********************************************************/

mach_port_t
mig_get_reply_port()
{
	mach_port_t port;

	if (!mig_reply_key_ready())
		return (MACH_PORT_NULL);
	port = (mach_port_t)(uintptr_t)pthread_getspecific(mig_reply_key);
	if (port == MACH_PORT_NULL) {
		port = mach_reply_port();
		if (port != MACH_PORT_NULL && pthread_setspecific(mig_reply_key,
		    (void *)(uintptr_t)port) != 0) {
			mig_reply_destroy((void *)(uintptr_t)port);
			return (MACH_PORT_NULL);
		}
	}
	return (port);
}

/*************************************************************
 *  Called by mig interfaces after a timeout on the port.
 *  Could be called by user.
 ***********************************************************/

void
mig_dealloc_reply_port(
	mach_port_t	reply_port __unused)
{
	mach_port_t port;

	if (!mig_reply_key_ready())
		return;
	port = (mach_port_t)(uintptr_t)pthread_getspecific(mig_reply_key);
	if (port == MACH_PORT_NULL)
		return;
	/* Clear first: neither a later MIG call nor the exit destructor owns it. */
	if (pthread_setspecific(mig_reply_key, NULL) == 0)
		mig_reply_destroy((void *)(uintptr_t)port);
}

/*************************************************************
 *  Called by mig interfaces after each RPC.
 *  Could be called by user.
 ***********************************************************/

void
mig_put_reply_port(
	mach_port_t	reply_port __unused)
{
}
