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
 * MkLinux
 */
/* CMU_HIST */
/*
 * Revision 2.17.3.7  92/09/15  17:20:54  jeffreyh
 * 	Added code to detect if a race condition was lost in the NORMA
 * 	system  and our port is now a proxy (migrated out from under the
 * 	thread), in which case we return MACH_RCV_PORT_CHANGED.
 * 	[92/07/24            sjs]
 * 
 * Revision 2.17.3.6  92/06/24  17:59:57  jeffreyh
 * 	Allow norma_ipc_send to fail.
 * 	[92/06/02            dlb]
 * 
 * Revision 2.17.3.5  92/05/27  00:44:23  jeffreyh
 * 	In ipc_mqueue_receive, check whether a kmsg got queued while we called
 * 	netipc_replenish.
 * 	[92/05/12            dlb]
 * 
 * Revision 2.17.3.4.2.1  92/04/28  16:01:59  jeffreyh
 * 	Fixed race condition in NORMA system for ipc_mqueue_send().
 * 	[92/04/16            sjs]
 * 
 * Revision 2.17.3.4  92/03/28  10:09:17  jeffreyh
 * 	In error cases call norma_ipc_error_receiving instead
 * 	of norma_ipc_finish receiving.  This may eat the kmsg.
 * 	[92/03/20		dlb]
 * 
 * Revision 2.17.3.3  92/03/03  16:18:53  jeffreyh
 * 	Changes from TRUNK
 * 	[92/02/26  11:51:40  jeffreyh]
 * 
 * Revision 2.18  92/01/03  20:13:05  dbg
 * 	Removed THREAD_SHOULD_TERMINATE.
 * 	[91/12/19            dbg]
 * 
 * Revision 2.17.3.2  92/01/21  21:50:26  jsb
 * 	Picked up hack from dlb@osf.org to call norma_ipc_finish_receiving
 * 	before ipc_kmsg_destroy. The real fix is to use uncopyout_to_network.
 * 	[92/01/17  14:35:03  jsb]
 * 
 * Revision 2.17.3.1  92/01/03  16:35:24  jsb
 * 	Removed spurious arguments to norma_ipc_send.
 * 	Options and timeout will be handled here, not by norma_ipc_send.
 * 	[91/12/26  19:51:59  jsb]
 * 
 * 	Corrected log.
 * 	[91/12/24  14:15:11  jsb]
 *
 * Revision 2.17  91/12/15  10:40:33  jsb
 * 	Added norma_ipc_finish_receiving call to support large in-line msgs.
 * 
 * Revision 2.16  91/12/14  14:27:10  jsb
 * 	Removed ipc_fields.h hack.
 * 
 * Revision 2.15  91/11/14  16:56:07  rpd
 * 	Picked up mysterious norma changes.
 * 	[91/11/14            rpd]
 * 
 * Revision 2.14  91/08/28  11:13:34  jsb
 * 	Added seqno argument to ipc_mqueue_receive.
 * 	Also added seqno processing to ipc_mqueue_send, ipc_mqueue_move.
 * 	[91/08/10            rpd]
 * 	Fixed norma_ipc_handoff technology.
 * 	Renamed clport things to norma_ipc things.
 * 	[91/08/15  08:23:17  jsb]
 * 
 * Revision 2.13  91/08/03  18:18:27  jsb
 * 	Renamed replenish routine.
 * 	[91/08/01  23:00:06  jsb]
 * 
 * 	Removed obsolete include.
 * 	Added option, timeout parameters to ipc_clport_send.
 * 	[91/07/17  14:04:15  jsb]
 * 
 * Revision 2.12  91/06/25  10:27:34  rpd
 * 	Added some wait_result assertions.
 * 	[91/05/30            rpd]
 * 
 * Revision 2.11  91/06/17  15:46:18  jsb
 * 	Renamed NORMA conditionals.
 * 	[91/06/17  10:44:39  jsb]
 * 
 * Revision 2.10  91/06/06  17:06:06  jsb
 * 	Added call to ip_unlock after calling ipc_clport_send.
 * 	Added support for clport handoff.
 * 	[91/06/06  16:05:12  jsb]
 * 
 * Revision 2.9  91/05/14  16:33:58  mrt
 * 	Correcting copyright
 * 
 * Revision 2.8  91/03/16  14:48:18  rpd
 * 	Renamed ipc_thread_{go,will_wait,will_wait_with_timeout}
 * 	to thread_{go,will_wait,will_wait_with_timeout}.
 * 	Replaced ipc_thread_block with thread_block.
 * 	[91/02/17            rpd]
 * 
 * Revision 2.7  91/02/05  17:22:24  mrt
 * 	Changed to new Mach copyright
 * 	[91/02/01  15:46:33  mrt]
 * 
 * Revision 2.6  91/01/08  15:14:35  rpd
 * 	Changed continuation argument to (void (*)()).
 * 	[90/12/18            rpd]
 * 	Reorganized ipc_mqueue_receive.
 * 	[90/11/22            rpd]
 * 
 * 	Minor cleanup.
 * 	[90/11/11            rpd]
 * 
 * Revision 2.5  90/12/14  11:02:32  jsb
 * 	Changed parameters in ipc_clport_send call.
 * 	[90/12/13  21:20:13  jsb]
 * 
 * Revision 2.4  90/11/05  14:29:04  rpd
 * 	Use new io_reference and io_release.
 * 	Use new ip_reference and ip_release.
 * 	[90/10/29            rpd]
 * 
 * Revision 2.3  90/09/28  16:54:58  jsb
 * 	Added NORMA_IPC support.
 * 	[90/09/28  14:03:24  jsb]
 * 
 * Revision 2.2  90/06/02  14:50:39  rpd
 * 	Created for new IPC.
 * 	[90/03/26  20:57:06  rpd]
 */
/* CMU_ENDHIST */
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
 */
/*
 *	File:	ipc/ipc_mqueue.c
 *	Author:	Rich Draves
 *	Date:	1989
 *
 *	Functions to manipulate IPC message queues.
 */


#include <sys/mach/port.h>
#include <sys/mach/message.h>
#include <sys/mach/ipc_kobject.h>

#include <sys/mach/ipc/ipc_mqueue.h>
#include <sys/mach/ipc/ipc_thread.h>
#include <sys/mach/ipc/ipc_kmsg.h>
#include <sys/mach/ipc/ipc_port.h>
#include <sys/mach/ipc/ipc_pset.h>
#include <sys/mach/ipc/ipc_space.h>
#include <sys/mach/thread.h>


/*
 *	Routine:	ipc_mqueue_init
 *	Purpose:
 *		Initialize a newly-allocated message queue.
 */

void
ipc_mqueue_init(
	ipc_mqueue_t	mqueue)
{
	ipc_kmsg_queue_init(&mqueue->imq_messages);
}

/*
 *	Routine:	ipc_mqueue_send
 *	Purpose:
 *		Send a message to a port.  The message holds a reference
 *		for the destination port in the msgh_remote_port field.
 *
 *		If unsuccessful, the caller still has possession of
 *		the message and must do something with it.  If successful,
 *		the message is queued, given to a receiver, destroyed,
 *		or handled directly by the kernel via mach_msg.
 *	Conditions:
 *		Nothing locked.
 *	Returns:
 *		MACH_MSG_SUCCESS	The message was accepted.
 *		MACH_SEND_TIMED_OUT	Caller still has message.
 *		MACH_SEND_INTERRUPTED	Caller still has message.
 */

mach_msg_return_t
ipc_mqueue_send(
	ipc_kmsg_t		kmsg,
	mach_msg_option_t	option,
	mach_msg_timeout_t	timeout)
{
	ipc_port_t port;
	kern_return_t           save_wait_result;

	port = (ipc_port_t) kmsg->ikm_header->msgh_remote_port;
	assert(IP_VALID(port));
	MACH_VERIFY(io_otype((ipc_object_t)port) == IOT_PORT, ("bad type %d\n", io_otype((ipc_object_t)port)));
	assert(io_otype((ipc_object_t)port) == IOT_PORT);

	ip_lock(port);

	if (port->ip_receiver == ipc_space_kernel) {
		ipc_kmsg_t reply;

		/*
		 *	We can check ip_receiver == ipc_space_kernel
		 *	before checking that the port is active because
		 *	ipc_port_dealloc_kernel clears ip_receiver
		 *	before destroying a kernel port.
		 */

		assert(ip_active(port));
		ip_unlock(port);

		reply = ipc_kobject_server(kmsg);
		if (reply != IKM_NULL) {
			ipc_mqueue_send_always(reply);
		}
#ifdef INVARIANTS
		else
			printf("reply from kobject == NULL\n");
#endif
		return MACH_MSG_SUCCESS;
	}

	if (kmsg->ikm_header->msgh_bits & MACH_MSGH_BITS_CIRCULAR) {
		ip_unlock(port);

		/* don't allow the creation of a circular loop */

		ipc_kmsg_destroy(kmsg);
		return MACH_MSG_SUCCESS;
	}

	for (;;) {
		ipc_thread_t self;

		/*
		 *	Can't deliver to a dead port.
		 *	However, we can pretend it got sent
		 *	and was then immediately destroyed.
		 */

		if (!ip_active(port)) {
			/*
			 *	We can't let ipc_kmsg_destroy deallocate
			 *	the port right, because we might end up
			 *	in an infinite loop trying to deliver
			 *	a send-once notification.
			 */

			ip_unlock(port);
			ip_release(port);
			kmsg->ikm_header->msgh_remote_port = MACH_PORT_NULL;
			ipc_kmsg_destroy(kmsg);
			return MACH_MSG_SUCCESS;
		}

		/*
		 *  Don't block if:
		 *	1) We're under the queue limit.
		 *	2) Caller used the MACH_SEND_ALWAYS internal option.
		 *	3) Message is sent to a send-once right.
		 */

		if ((port->ip_msgcount < port->ip_qlimit) ||
		    (option & MACH_SEND_ALWAYS) ||
		    (MACH_MSGH_BITS_REMOTE(kmsg->ikm_header->msgh_bits) ==
						MACH_MSG_TYPE_PORT_SEND_ONCE))
			break;

		/* must block waiting for queue to clear */

		self = current_thread();

		if (option & MACH_SEND_TIMEOUT) {
			if (timeout == 0) {
				ip_unlock(port);
				return MACH_SEND_TIMED_OUT;
			}
			thread_will_wait_with_timeout(self, timeout);
		} else {
			thread_will_wait(self);
		}

		counter(c_ipc_mqueue_send_block++);
		self->ith_state = MACH_SEND_IN_PROGRESS;
		self->ith_block_lock_data = &port->port_comm.rcd_io_lock_data;
		ipc_thread_enqueue(&port->ip_blocked, self);
		thread_block();

		/* Save proper wait_result in case we block */
		save_wait_result = self->wait_result;

		/* why did we wake up? - finish_receive will remove us from the queue */

		if (self->ith_state == MACH_MSG_SUCCESS)
			continue;
		ipc_thread_rmqueue(&port->ip_blocked, self);
		assert(self->ith_state == MACH_SEND_IN_PROGRESS);

		/*
		 *	Thread wakeup-reason field tells us why
		 *	the wait was interrupted.
		 */

		switch (save_wait_result) {
		    case THREAD_INTERRUPTED:
			/* send was interrupted - give up */

			ip_unlock(port);
			return MACH_SEND_INTERRUPTED;

		    case THREAD_TIMED_OUT:
			/* timeout expired */

			assert(option & MACH_SEND_TIMEOUT);
			timeout = 0;
			break;

		    case THREAD_RESTART:
		    default:
				panic("ipc_mqueue_send %d", save_wait_result);
		}
	}
	(void) ipc_mqueue_deliver(port, kmsg, TRUE);

	return MACH_MSG_SUCCESS;
}


/*
 * ipc_mqueue_deliver: give the kmsg to a waiting receiver or else enqueue
 * it on the port or pset.
 *
 * ipc_mqueue_deliver used to be the last block of code in ipc_mqueue_send.
 * It is split out here so that the same code can be used to deliver DIPC
 * kmsgs or meta_kmsgs.
 *
 * The port must be locked on entry; it will be unlocked on exit.  This
 * routine CAN NOT FAIL when called from thread context.  However, from
 * interrupt context it may not be able to complete its duties due to
 * lock contention.
 *
 * Returns TRUE on successful delivery.
 */
#if	TRACE_BUFFER
int	tr_ipc_mqueue_deliver = 0;
#define	TR_IPC_MQEN(fmt, port, kmsg, thread_context)			\
	tr_start();							\
	if (tr_ipc_mqueue_deliver)					\
		tr4((fmt), (port), (kmsg), (thread_context));
#define	TR_IPC_MQEX(fmt, kmsg)						\
	if (tr_ipc_mqueue_deliver)					\
		tr2((fmt), (kmsg));					\
	tr_stop();
#else	/* TRACE_BUFFER */
#define	TR_IPC_MQEN(fmt, port, kmsg, thread_context)
#define	TR_IPC_MQEX(fmt, kmsg)
#endif	/* TRACE_BUFFER */


mach_msg_return_t
ipc_mqueue_deliver(
	register ipc_port_t	port,
	register ipc_kmsg_t	kmsg,
	boolean_t		thread_context)
{
	ipc_mqueue_t mqueue;
	ipc_pset_t pset;

	TR_DECL("ipc_mqueue_deliver");

	TR_IPC_MQEN("enter: port 0x%x kmsg 0x%x thd_ctxt %d", port, kmsg,
		    thread_context);

	assert(IP_VALID(port));
	assert(ip_active(port));

	pset = port->ip_pset;
	mqueue = &port->ip_messages;
	assert(port->ip_msgcount >= 0);
	ipc_kmsg_enqueue_macro(&mqueue->imq_messages, kmsg);
	port->ip_msgcount++;
	/* Enqueue and receive enrollment share the receiving object's interlock. */
	wakeup(port);
	if (pset) {
		ips_lock(pset);
		wakeup(pset);
		ips_unlock(pset);
	}
	/* Membership may disappear as soon as the port is unlocked. */
	if (pset)
		ips_reference(pset);
	ip_unlock(port);

	if (pset) {
		ipc_pset_signal(pset);
		ips_release(pset);
	}

	TR_IPC_MQEX("exit: queued 0x%x", port);
	return MACH_MSG_SUCCESS;
}


/*
 *	Routine:	ipc_mqueue_copyin
 *	Purpose:
 *		Convert a name in a space to a message queue.
 *	Conditions:
 *		Nothing locked.  If successful, the message queue
 *		is returned locked and caller gets a ref for the object.
 *		This ref ensures the continued existence of the queue.
 *	Returns:
 *		MACH_MSG_SUCCESS	Found a message queue.
 *		MACH_RCV_INVALID_NAME	The space is dead.
 *		MACH_RCV_INVALID_NAME	The name doesn't denote a right.
 *		MACH_RCV_INVALID_NAME
 *			The denoted right is not receive or port set.
 *		MACH_RCV_IN_SET		Receive right is a member of a set.
 */

mach_msg_return_t
ipc_mqueue_copyin(
	ipc_space_t	space,
	mach_port_name_t	name,
	ipc_entry_bits_t		*bitsp,
	ipc_object_t		*objectp,
	ipc_entry_t *entryp)
{
	ipc_entry_t entry;
	ipc_entry_bits_t bits;
	ipc_object_t object;
	mach_msg_return_t mr;

	is_read_lock(space);
	if (!space->is_active) {
		mr = MACH_RCV_INVALID_NAME;
		goto error;
	}

	entry = ipc_entry_lookup(space, name);
	if (entry == IE_NULL) {
		mr = MACH_RCV_INVALID_NAME;
		goto error;
	}

	bits = entry->ie_bits;
	object = entry->ie_object;
	if ((bits & (MACH_PORT_TYPE_RECEIVE | MACH_PORT_TYPE_PORT_SET)) == 0 ||
	    object == IO_NULL) {
		mr = MACH_RCV_INVALID_NAME;
		goto error;
	}
	ipc_object_reference(object);
	ipc_entry_reference(entry);
	io_lock(object);
	current_thread()->ith_receive_epoch = (bits & MACH_PORT_TYPE_PORT_SET) ?
	    ((ipc_pset_t)object)->ips_receive_epoch : ((ipc_port_t)object)->ip_receive_epoch;

	if (bits & MACH_PORT_TYPE_RECEIVE) {
		assert((ipc_port_t)object != IP_NULL);

		assert(ip_active((ipc_port_t)object));
		assert(((ipc_port_t)object)->ip_receiver_name == name);
		assert(((ipc_port_t)object)->ip_receiver == space);
		is_read_unlock(space);
	} else if (bits & MACH_PORT_TYPE_PORT_SET) {
		assert((ipc_pset_t)object != IPS_NULL);

		assert(ips_active((ipc_pset_t)object));
		assert(((ipc_pset_t)object)->ips_local_name == name);
		is_read_unlock(space);
	}

	/*
	 *	At this point, the object is locked and active,
	 *	the space is unlocked, and mqueue is initialized.
	 */

	io_unlock(object);
	*objectp = object;
	*bitsp = bits;
	*entryp = entry;
	return MACH_MSG_SUCCESS;
error:
	is_read_unlock(space);
	return (mr);
}


static void
ipc_mqueue_post_on_thread(
	ipc_port_t			port,
	mach_msg_option_t	option,
	mach_msg_size_t		max_size,
	thread_t                thread)
{
	ipc_kmsg_t kmsg;
	ipc_mqueue_t 	mqueue = &port->ip_messages;

	mach_msg_return_t mr = MACH_MSG_SUCCESS;
	mach_msg_size_t rcv_size;
	vm_map_t map = current_map();

	/*
	 * Do some sanity checking of our ability to receive
	 * before pulling the message off the queue.
	 */
	kmsg = ipc_kmsg_queue_first(&mqueue->imq_messages);
	assert(kmsg != IKM_NULL);

	/*
	 * If we really can't receive it, but we had the
	 * MACH_RCV_LARGE option set, then don't take it off
	 * the queue, instead return the appropriate error
	 * (and size needed).
	 */
	rcv_size = ipc_kmsg_copyout_size(kmsg, map);
	if (rcv_size > max_size ||
	    round_msg(rcv_size) < rcv_size || round_msg(rcv_size) > max_size ||
	    REQUESTED_TRAILER_SIZE(option) > max_size - round_msg(rcv_size)) {
		mr = MACH_RCV_TOO_LARGE;
		if (option & MACH_RCV_LARGE) {
			thread->ith_receiver_name = port->ip_receiver_name;
			thread->ith_kmsg = IKM_NULL;
			thread->ith_msize = rcv_size;
			thread->ith_seqno = 0;
			thread->ith_state = mr;
			return;
		}
	}

	ipc_kmsg_rmqueue_first_macro(&mqueue->imq_messages, kmsg);
	assert(port->ip_msgcount > 0);
	port->ip_msgcount--;

	thread->ith_object = (ipc_object_t)port;
	thread->ith_seqno = port->ip_seqno++;
	thread->ith_receive_context = port->ip_context;
	thread->ith_kmsg = kmsg;
	thread->ith_state = mr;

	current_task()->messages_received++;
}

mach_msg_return_t
ipc_mqueue_pset_receive(
	natural_t	bits,
	mach_msg_option_t	option,
	mach_msg_size_t		max_size,
	mach_msg_timeout_t	timeout,
	thread_t thread)
{
	ipc_port_t port;
	ipc_pset_t pset;
	boolean_t port_ref;

	pset = (ipc_pset_t)thread->ith_object;
	assert(io_otype(thread->ith_object) == IOT_PORT_SET);
restart:
	if (!ips_active(pset)) {
		thread->ith_state = MACH_RCV_PORT_DIED;
		return THREAD_NOT_WAITING;
	}
	if (pset->ips_receive_epoch != thread->ith_receive_epoch) {
		thread->ith_state = MACH_RCV_PORT_CHANGED;
		return THREAD_NOT_WAITING;
	}
	port_ref = FALSE;
	TAILQ_FOREACH(port, &pset->ips_ports, ip_next) {
		mtx_assert(&port->port_comm.rcd_io_lock_data, MA_NOTOWNED);
		assert (port->ip_msgcount >= 0);
		if (port->ip_msgcount != 0) {
			if (ip_lock_try(port) == 0) {
				/*
				 * The pset lock proves list membership, but dropping
				 * it lets a concurrent receive-right destruction remove
				 * and free the port before the blocking lock succeeds.
				 */
				ip_reference(port);
				port_ref = TRUE;
				ips_unlock(pset);
				ip_lock(port);
				ips_lock(pset);
				if (!ips_active(pset) || pset->ips_receive_epoch != thread->ith_receive_epoch ||
				    !ip_active(port) || port->ip_pset != pset || port->ip_msgcount == 0) {
					ip_unlock(port);
					ip_release(port);
					goto restart;
				}
			}
			/* one way or another we have the lock */
			break;
		}
	}
	if (port != NULL && port->ip_msgcount == 0) {
		mtx_assert(&port->port_comm.rcd_io_lock_data, MA_OWNED);
		ip_unlock(port);
		if (port_ref)
			ip_release(port);
		goto restart;
	}
	if (port != NULL) {
		mtx_assert(&port->port_comm.rcd_io_lock_data, MA_OWNED);
		ipc_mqueue_post_on_thread(port, option, max_size, thread);
		ip_unlock(port);
		if (port_ref)
			ip_release(port);
		thread->ith_object = (ipc_object_t)port;
		return (THREAD_NOT_WAITING);
	}
	if ((option & MACH_RCV_TIMEOUT) && (timeout == 0)) {
		thread->ith_state = MACH_RCV_TIMED_OUT;
		return (THREAD_NOT_WAITING);
	}

	return (THREAD_WAITING);
}

/*
 *	Routine:	ipc_mqueue_receive
 *	Purpose:
 *		Receive a message from a message queue.
 *
 *	Conditions:
 *		The message queue is locked; it will be returned unlocked.
 *
 *		Our caller must hold a reference for the port or port set
 *		to which this queue belongs, to keep the queue
 *		from being deallocated.  Furthermore, the port or set
 *		must have been active when the queue was locked.
 *
 *		The kmsg is returned with clean header fields
 *		and with the circular bit turned off.
 *	Returns:
 *		MACH_MSG_SUCCESS	Message returned in kmsgp.
 *		MACH_RCV_TOO_LARGE	Message size returned in kmsgp.
 *		MACH_RCV_TIMED_OUT	No message obtained.
 *		MACH_RCV_INTERRUPTED	No message obtained.
 *		MACH_RCV_PORT_DIED	Port/set died; no message.
 *		MACH_RCV_PORT_CHANGED	Port moved into set; no msg.
 *
 */


mach_msg_return_t
ipc_mqueue_receive(natural_t bits, mach_msg_option_t option,
    mach_msg_size_t max_size, mach_msg_timeout_t timeout,
    ipc_kmsg_t *kmsgp, mach_port_seqno_t *seqnop, thread_t thread)
{
    ipc_object_t admitted = thread->ith_object;
    ipc_port_t port;
    ipc_pset_t pset;
    mach_msg_return_t mr;
    sbintime_t deadline = 0;
    uint64_t epoch;
    int error, rc;

    MPASS(thread == current_thread());
    *kmsgp = IKM_NULL;
    thread->ith_kmsg = IKM_NULL;
    if (option & MACH_RCV_TIMEOUT)
        deadline = sbinuptime() + (sbintime_t)timeout * SBT_1MS;
    io_lock(admitted);
    for (;;) {
        if (!io_active(admitted)) {
            mr = MACH_RCV_PORT_DIED;
            break;
        }
        epoch = (bits & MACH_PORT_TYPE_PORT_SET) ?
            ((ipc_pset_t)admitted)->ips_receive_epoch :
            ((ipc_port_t)admitted)->ip_receive_epoch;
        if (epoch != thread->ith_receive_epoch) {
            mr = MACH_RCV_PORT_CHANGED;
            break;
        }
        thread->ith_object = admitted;
        thread->ith_kmsg = IKM_NULL;
        if (bits & MACH_PORT_TYPE_PORT_SET) {
            pset = (ipc_pset_t)admitted;
            rc = ipc_mqueue_pset_receive(bits, option, max_size, 0, thread);
            if (rc == THREAD_NOT_WAITING && thread->ith_state != MACH_RCV_TIMED_OUT) {
                mr = thread->ith_state;
                if (thread->ith_kmsg == IKM_NULL)
                    break;
                port = (ipc_port_t)thread->ith_object;
                /* The dequeued kmsg owns the destination-port reference. */
                ips_unlock(pset);
                ip_lock(port);
                *kmsgp = thread->ith_kmsg;
                *seqnop = thread->ith_seqno;
                mr = ipc_mqueue_finish_receive(kmsgp, port, option, max_size);
                ip_unlock(port);
                goto out;
            }
        } else {
            port = (ipc_port_t)admitted;
            if (!ipc_kmsg_queue_empty(&port->ip_messages.imq_messages)) {
                ipc_mqueue_post_on_thread(port, option, max_size, thread);
                mr = thread->ith_state;
                if (thread->ith_kmsg != IKM_NULL) {
                    *kmsgp = thread->ith_kmsg;
                    *seqnop = thread->ith_seqno;
                    mr = ipc_mqueue_finish_receive(kmsgp, port, option, max_size);
                }
                break;
            }
        }
        if ((option & MACH_RCV_TIMEOUT) && (timeout == 0 || sbinuptime() >= deadline)) {
            mr = MACH_RCV_TIMED_OUT;
            break;
        }
        error = msleep_sbt(admitted, &((rpc_common_t)admitted)->rcd_io_lock_data,
            PCATCH, "machrcv", deadline, 0,
            (option & MACH_RCV_TIMEOUT) ? C_ABSOLUTE : 0);
        if (error == EINTR || error == ERESTART) {
            mr = MACH_RCV_INTERRUPTED;
            break;
        }
        if (error == EWOULDBLOCK) {
            mr = MACH_RCV_TIMED_OUT;
            break;
        }
        /* A wakeup only requests revalidation and another locked dequeue. */
    }
    io_unlock(admitted);
out:
    thread->ith_state = mr;
    thread->ith_kmsg = IKM_NULL;
    thread->ith_object = IO_NULL;
    return mr;
}

mach_msg_return_t
ipc_mqueue_finish_receive(
	ipc_kmsg_t		*kmsgp,
	ipc_port_t		port,
	mach_msg_option_t	option,
	mach_msg_size_t		max_size)
{
	ipc_kmsg_t		kmsg;
	mach_msg_return_t	mr;
	ipc_thread_t 		self = current_thread();
	mach_msg_size_t rcv_size;

	mr = MACH_MSG_SUCCESS;
	kmsg = *kmsgp;
	/* check sizes */

	rcv_size = ipc_kmsg_copyout_size(kmsg, thread_map(self));
	if (rcv_size > max_size ||
	    round_msg(rcv_size) < rcv_size || round_msg(rcv_size) > max_size ||
	    REQUESTED_TRAILER_SIZE(option) > max_size - round_msg(rcv_size)) {
		/* the receive buffer isn't large enough */
		if (mach_debug_enable) {
			printf("%s max_size=%d REQUESTED_TRAILER_SIZE(option=%d)=%d\n",
				   curthread->td_proc->p_comm, max_size, option, REQUESTED_TRAILER_SIZE(option));
			/* ipc_kmsg_print(kmsg); */
			printf("rcv_size=%d\n", rcv_size);
		}
		mr = MACH_RCV_TOO_LARGE;
	} else if (self->ith_scatter_list != MACH_MSG_BODY_NULL) {
		/* verify the scatter list */
		mr = ipc_kmsg_check_scatter(kmsg,
					self->ith_option,
					&self->ith_scatter_list,
					&self->ith_scatter_list_size);
	}

	if (mr == MACH_MSG_SUCCESS) {
		assert((kmsg->ikm_header->msgh_bits & MACH_MSGH_BITS_CIRCULAR)
									== 0);
	}

	if (ip_active(port)) {
		ipc_thread_queue_t senders;
		ipc_thread_t sender;

		assert(port->ip_msgcount >= 0);
		senders = &port->ip_blocked;
		sender = ipc_thread_queue_first(senders);

		MPASS(sender == NULL || sender->ith_state == MACH_SEND_IN_PROGRESS);

		if ((sender != ITH_NULL) &&
			(port->ip_msgcount < port->ip_qlimit)) {
			ipc_thread_rmqueue(senders, sender);
			sender->ith_state = MACH_MSG_SUCCESS;
			thread_go(sender);
		}
	}
	*kmsgp = kmsg;
	return mr;
}
