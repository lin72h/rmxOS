/*-
 * Copyright (c) 2014-2015, Matthew Macy <mmacy@nextbsd.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *
 *  2. Neither the name of Matthew Macy nor the names of its
 *     contributors may be used to endorse or promote products derived from
 *     this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

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
 * Revision 2.5  91/05/14  16:35:47  mrt
 * 	Correcting copyright
 * 
 * Revision 2.4  91/02/05  17:23:15  mrt
 * 	Changed to new Mach copyright
 * 	[91/02/01  15:50:24  mrt]
 * 
 * Revision 2.3  90/11/05  14:29:47  rpd
 * 	Use new ips_reference and ips_release.
 * 	[90/10/29            rpd]
 * 
 * Revision 2.2  90/06/02  14:51:19  rpd
 * 	Created for new IPC.
 * 	[90/03/26  21:01:53  rpd]
 * 
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
 *	File:	ipc/ipc_pset.c
 *	Author:	Rich Draves
 *	Date:	1989
 *
 *	Functions to manipulate IPC port sets.
 */

#include <sys/cdefs.h>
#include <sys/types.h>
#include <sys/event.h>
#include <sys/malloc.h>
#include <sys/taskqueue.h>
#include <sys/kernel.h>



#define MACH_INTERNAL
#include <sys/mach/port.h>
#include <sys/mach/kern_return.h>
#include <sys/mach/message.h>
#include <sys/mach/ipc/ipc_kmsg.h>
#include <sys/mach/ipc/ipc_mqueue.h>
#include <sys/mach/ipc/ipc_object.h>
#include <sys/mach/ipc/ipc_port.h>
#include <sys/mach/ipc/ipc_pset.h>
#include <sys/mach/ipc/ipc_right.h>
#include <sys/mach/ipc/ipc_space.h>
#include <sys/mach/ipc/ipc_print.h>

#include <sys/mach/thread.h>

static void
kn_sx_lock(void *arg)
{
	struct sx *lock = arg;

	sx_xlock(lock);
}

static void
kn_sx_unlock(void *arg)
{
	struct sx *lock = arg;

	sx_xunlock(lock);
}

static void
sx_assert_locked(void *arg, int what)
{
	sx_assert((struct sx *)arg, what);
}

static struct taskqueue *ipc_pset_work_queue;
static struct task ipc_pset_work_task;
static struct mtx ipc_pset_work_lock;
static TAILQ_HEAD(, ipc_pset) ipc_pset_pending =
    TAILQ_HEAD_INITIALIZER(ipc_pset_pending);

/* The task lives in the module, never in a set that this worker can free. */
static void
ipc_pset_work(void *context __unused, int pending __unused)
{
	ipc_pset_t pset;
	uint64_t dirty;

	for (;;) {
		mtx_lock(&ipc_pset_work_lock);
		pset = TAILQ_FIRST(&ipc_pset_pending);
		if (pset == IPS_NULL) {
			mtx_unlock(&ipc_pset_work_lock);
			return;
		}
		dirty = pset->ips_work_dirty;
		mtx_unlock(&ipc_pset_work_lock);

		/* No Mach object, space, task or work mutex is held here. */
		KNOTE_UNLOCKED(&pset->ips_note, 0);

		mtx_lock(&ipc_pset_work_lock);
		if (dirty != pset->ips_work_dirty) {
			/* Rotate dirty work; other sets must also make progress. */
			TAILQ_REMOVE(&ipc_pset_pending, pset, ips_work_link);
			TAILQ_INSERT_TAIL(&ipc_pset_pending, pset, ips_work_link);
			mtx_unlock(&ipc_pset_work_lock);
			continue;
		}
		TAILQ_REMOVE(&ipc_pset_pending, pset, ips_work_link);
		pset->ips_work_queued = FALSE;
		mtx_unlock(&ipc_pset_work_lock);
		/* Last access to this set; all its work has completed. */
		ips_release(pset);
	}
}

int
ipc_pset_work_init(void)
{
	mtx_init(&ipc_pset_work_lock, "Mach pset work", NULL, MTX_DEF);
	TASK_INIT(&ipc_pset_work_task, 0, ipc_pset_work, NULL);
	ipc_pset_work_queue = taskqueue_create("mach_pset", M_WAITOK,
	    taskqueue_thread_enqueue, &ipc_pset_work_queue);
	return (0);
}

static void
ipc_pset_work_start(void *arg __unused)
{
	int error;

	/* Module initialization may have failed and freed the queue. */
	if (ipc_pset_work_queue == NULL)
		return;
	/* Pending work remains queued until this thread can run. */
	error = taskqueue_start_threads(&ipc_pset_work_queue, 1, PI_SOFT,
	    "Mach pset notification");
	if (error != 0)
		panic("Mach pset notification worker start failed: %d", error);
	printf("Mach pset notification worker started\n");
}

/* Also executed in subsystem order by the linker for a runtime KLD load. */
SYSINIT(mach_pset_work, SI_SUB_TASKQ, SI_ORDER_SECOND,
    ipc_pset_work_start, NULL);

void
ipc_pset_work_fini(void)
{
	/* Only after producers/hooks are unavailable, outside all Mach locks. */
	taskqueue_drain_all(ipc_pset_work_queue);
	taskqueue_free(ipc_pset_work_queue);
	ipc_pset_work_queue = NULL;
	mtx_destroy(&ipc_pset_work_lock);
}

void
ipc_pset_signal(ipc_pset_t pset)
{
	/* Caller holds a storage reference, usually membership + the set lock. */
	mtx_lock(&ipc_pset_work_lock);
	pset->ips_work_dirty++;
	if (!pset->ips_work_queued) {
		ips_reference(pset);
		pset->ips_work_queued = TRUE;
		TAILQ_INSERT_TAIL(&ipc_pset_pending, pset, ips_work_link);
		taskqueue_enqueue(ipc_pset_work_queue, &ipc_pset_work_task);
	}
	mtx_unlock(&ipc_pset_work_lock);
}

static void
ipc_pset_publish(ipc_pset_t pset)
{
	ipc_port_t first;
	uint64_t snapshot;

	MPASS(ips_lock_owned(pset));
	first = TAILQ_FIRST(&pset->ips_ready);
	snapshot = ips_active(pset) && !pset->ips_readiness_revoked &&
	    first != IP_NULL ? (UINT64_C(1) << 32) | first->ip_receiver_name : 0;
	atomic_store_rel_64(&pset->ips_ready_snapshot, snapshot);
	ipc_pset_signal(pset);
}

void
ipc_pset_port_ready(ipc_pset_t pset, ipc_port_t port, boolean_t rotate)
{
	boolean_t ready;

	MPASS(io_lock_owned((ipc_object_t)port) && ips_lock_owned(pset));
	MPASS(port->ip_pset == pset);
	ready = ip_active(port) && !port->ip_readiness_revoked &&
	    port->ip_msgcount != 0;
	if (port->ip_on_ready_list && (!ready || rotate)) {
		TAILQ_REMOVE(&pset->ips_ready, port, ip_ready_link);
		port->ip_on_ready_list = FALSE;
	}
	if (ready && !port->ip_on_ready_list) {
		TAILQ_INSERT_TAIL(&pset->ips_ready, port, ip_ready_link);
		port->ip_on_ready_list = TRUE;
	}
	ipc_pset_publish(pset);
}

void
ipc_pset_revoke(ipc_pset_t pset)
{
	MPASS(ips_lock_owned(pset));
	pset->ips_readiness_revoked = TRUE;
	ipc_pset_publish(pset);
}

void
io_validate(ipc_object_t io)
{
	if (io_otype(io) == IOT_PORT) {
		MPASS(((ipc_port_t)io)->ip_pset == NULL);
		assert(!ip_active((ipc_port_t)io));
	} else {
		MPASS(TAILQ_EMPTY(&((ipc_pset_t)io)->ips_ports));
		MPASS(TAILQ_EMPTY(&((ipc_pset_t)io)->ips_ready));
		MPASS(!((ipc_pset_t)io)->ips_work_queued);
	}

}

/*
 * Forward declarations
 */
void ipc_pset_add(
	ipc_pset_t	pset,
	ipc_port_t	port);

static void ipc_pset_port_changed(
	ipc_port_t	port,
	mach_msg_return_t mr);

/*
 *	Routine:	ipc_pset_alloc
 *	Purpose:
 *		Allocate a port set.
 *	Conditions:
 *		Nothing locked.  If successful, the port set is returned
 *		locked.  (The caller doesn't have a reference.)
 *	Returns:
 *		KERN_SUCCESS		The port set is allocated.
 *		KERN_INVALID_TASK	The space is dead.
 *		KERN_NO_SPACE		No room for an entry in the space.
 *		KERN_RESOURCE_SHORTAGE	Couldn't allocate memory.
 */

kern_return_t
ipc_pset_alloc(
	ipc_space_t	space,
	mach_port_name_t	*namep,
	ipc_pset_t	*psetp)
{
	ipc_pset_t pset;
	mach_port_name_t name;
	kern_return_t kr;

	kr = ipc_object_alloc(space, IOT_PORT_SET,
			      MACH_PORT_TYPE_PORT_SET,
			      &name, (ipc_object_t *) &pset);
	if (kr != KERN_SUCCESS)
		return kr;
	/* pset is locked */

	pset->ips_local_name = name;
	TAILQ_INIT(&pset->ips_ports);
	TAILQ_INIT(&pset->ips_ready);
	sx_init(&pset->ips_note_lock, "pset knote lock");
	knlist_init(&pset->ips_note, &pset->ips_note_lock,
				kn_sx_lock, kn_sx_unlock, sx_assert_locked);
	thread_pool_init(&pset->ips_thread_pool);
	*namep = name;
	*psetp = pset;
	return KERN_SUCCESS;
}

/*
 *	Routine:	ipc_pset_alloc_name
 *	Purpose:
 *		Allocate a port set, with a specific name.
 *	Conditions:
 *		Nothing locked.  If successful, the port set is returned
 *		locked.  (The caller doesn't have a reference.)
 *	Returns:
 *		KERN_SUCCESS		The port set is allocated.
 *		KERN_INVALID_TASK	The space is dead.
 *		KERN_NAME_EXISTS	The name already denotes a right.
 *		KERN_RESOURCE_SHORTAGE	Couldn't allocate memory.
 */

kern_return_t
ipc_pset_alloc_name(
	ipc_space_t	space,
	mach_port_name_t	name,
	ipc_pset_t	*psetp)
{
	ipc_pset_t pset;
	kern_return_t kr;


	kr = ipc_object_alloc_name(space, IOT_PORT_SET,
				   MACH_PORT_TYPE_PORT_SET,
				   name, (ipc_object_t *) &pset);
	if (kr != KERN_SUCCESS)
		return kr;
	/* pset is locked */

	pset->ips_local_name = name;
	TAILQ_INIT(&pset->ips_ports);
	TAILQ_INIT(&pset->ips_ready);
	sx_init(&pset->ips_note_lock, "pset knote lock");
	knlist_init(&pset->ips_note, &pset->ips_note_lock,
				kn_sx_lock, kn_sx_unlock, sx_assert_locked);
	thread_pool_init(&pset->ips_thread_pool);
	*psetp = pset;
	return KERN_SUCCESS;
}

/*
 *	Routine:	ipc_pset_add
 *	Purpose:
 *		Puts a port into a port set.
 *		The port set gains a reference.
 *	Conditions:
 *		Both port and port set are locked and active.
 *		The port isn't already in a set.
 *		The owner of the port set is also receiver for the port.
 */

void
ipc_pset_add(
	ipc_pset_t	pset,
	ipc_port_t	port)
{
	assert(ips_active(pset));
	assert(ip_active(port));
	assert(port->ip_pset == IPS_NULL);

	port->ip_pset = pset;
	ips_reference(pset);
	TAILQ_INSERT_TAIL(&pset->ips_ports, port, ip_next);
	ipc_pset_port_ready(pset, port, FALSE);
	if (port->ip_msgcount != 0)
		wakeup(pset);
}

/*
 *	Routine:	ipc_pset_remove
 *	Purpose:
 *		Removes a port from a port set.
 *		The port set loses a reference.
 *	Conditions:
 *		Both port and port set are locked.
 *		The port must be active.
 */

void
ipc_pset_remove(
	ipc_pset_t	pset,
	ipc_port_t	port)
{
	assert(ip_active(port));
	assert(port->ip_pset == pset);

	if (port->ip_on_ready_list) {
		TAILQ_REMOVE(&pset->ips_ready, port, ip_ready_link);
		port->ip_on_ready_list = FALSE;
	}
	port->ip_pset = IPS_NULL;
	port->ip_receive_epoch++;
	wakeup(port);
	wakeup(pset);
	TAILQ_REMOVE(&pset->ips_ports, port, ip_next);
	ipc_pset_publish(pset);
}

/*
 *	Routine:	ipc_pset_move
 *	Purpose:
 *		If nset is IPS_NULL, removes port
 *		from the port set it is in.  Otherwise, adds
 *		port to nset, removing it from any set
 *		it might already be in.
 *	Conditions:
 *		The space is read-locked.
 *	Returns:
 *		KERN_SUCCESS		Moved the port.
 *		KERN_NOT_IN_SET		nset is null and port isn't in a set.
 */

kern_return_t
ipc_pset_move(
	ipc_space_t	space,
	ipc_port_t	port,
	ipc_pset_t	nset)
{
	ipc_pset_t oset;
	int active;
	/*
	 *	While we've got the space locked, it holds refs for
	 *	the port and nset (because of the entries).  Also,
	 *	they must be alive.  While we've got port locked, it
	 *	holds a ref for oset, which might not be alive.
	 */

	ip_lock(port);
	assert(ip_active(port));

	oset = port->ip_pset;

	if (oset == nset) {
		/* the port is already in the new set:  a noop */

		is_read_unlock(space);
	} else if (oset == IPS_NULL) {
		/* just add port to the new set */

		ips_lock(nset);
		assert(ips_active(nset));
		is_read_unlock(space);

		ipc_pset_add(nset, port);
		ipc_pset_port_changed(port, MACH_RCV_PORT_CHANGED);
		ips_unlock(nset);
	} else if (nset == IPS_NULL) {
		/* just remove port from the old set */

		is_read_unlock(space);
		ips_lock(oset);

		ipc_pset_remove(oset, port);
		active = ips_active(oset);
		ips_unlock(oset);
		ips_release(oset);
		if (!active)
			oset = IPS_NULL; /* trigger KERN_NOT_IN_SET */
	} else {
		/* atomically move port from oset to nset */

		if (oset < nset) {
			ips_lock(oset);
			ips_lock(nset);
		} else {
			ips_lock(nset);
			ips_lock(oset);
		}

		is_read_unlock(space);
		assert(ips_active(nset));

		ipc_pset_remove(oset, port);
		ipc_pset_add(nset, port);


		ips_unlock(nset);
		ips_unlock(oset);	/* KERN_NOT_IN_SET not a possibility */
		ips_release(oset);
	}

	ip_unlock(port);

	return (((nset == IPS_NULL) && (oset == IPS_NULL)) ?
		KERN_NOT_IN_SET : KERN_SUCCESS);
}



/*
 *	Routine:	ipc_pset_changed
 *	Purpose:
 *		Wake up receivers waiting on pset.
 *	Conditions:
 *		The pset is locked.
 */

static void
ipc_pset_changed(
	ipc_pset_t		pset,
	mach_msg_return_t	mr)
{
	ipc_thread_t th;

	pset->ips_receive_epoch++;
	wakeup(pset);
	while ((th = thread_pool_get_act((ipc_object_t)pset, 0)) != ITH_NULL) {
		th->ith_state = mr;
		thread_go(th);
	}
}

static void
ipc_pset_port_changed(
	ipc_port_t		port,
	mach_msg_return_t	mr)
{
	ipc_thread_t th;

	port->ip_receive_epoch++;
	wakeup(port);
	while ((th = thread_pool_get_act((ipc_object_t)port, 0)) != ITH_NULL) {
		th->ith_state = mr;
		thread_go(th);
	}
}

/*
 *	Routine:	ipc_pset_destroy
 *	Purpose:
 *		Destroys a port_set.
 *
 *		Doesn't remove members from the port set;
 *		that happens lazily.  As members are removed,
 *		their messages are removed from the queue.
 *	Conditions:
 *		The port_set is locked and alive.
 *		The caller has a reference, which is consumed.
 *		Afterwards, the port_set is unlocked and dead.
 */

void
ipc_pset_destroy(
	ipc_pset_t	pset)
{
	ipc_port_t port;

	pset->ips_object.io_bits &= ~IO_BITS_ACTIVE;
	ipc_pset_publish(pset);
	while (!TAILQ_EMPTY(&pset->ips_ports)) {
		port = TAILQ_FIRST(&pset->ips_ports);
		MPASS(port->ip_pset == pset);
		if (ip_lock_try(port) == 0) {
			/* Keep this member alive while following port-before-set order. */
			ip_reference(port);
			ips_unlock(pset);
			ip_lock(port);
			ips_lock(pset);
			if (!ip_active(port) || port->ip_pset != pset) {
				ip_unlock(port);
				ip_release(port);
				continue;
			}
			ipc_pset_remove(pset, port);
			ip_unlock(port);
			ip_release(port);
			ips_release(pset);
			continue;
		}
		ipc_pset_remove(pset, port);
		ip_unlock(port);
		ips_release(pset);
	}
	ipc_pset_changed(pset, MACH_RCV_PORT_DIED);
	ips_unlock(pset);
	ips_release(pset);	/* consume the ref our caller gave us */
}

/**
 *
 * KQ handling
 */
  
#include <sys/file.h>
#include <sys/selinfo.h>
#include <sys/eventvar.h>

static int      filt_machportattach(struct knote *kn);
static void     filt_machportdetach(struct knote *kn);
static int      filt_machport(struct knote *kn, long hint);
struct filterops machport_filtops = {
	.f_isfd = 1,
	.f_attach = filt_machportattach,
	.f_detach = filt_machportdetach,
	.f_event = filt_machport,
};

struct machport_note {
	ipc_entry_t entry;
	ipc_pset_t pset;
};

static int
filt_machportattach(struct knote *kn)
{
	ipc_space_t space = current_space();
	ipc_entry_t entry;
	struct machport_note *note;

	if (kn->kn_fp->f_type != DTYPE_MACH_IPC)
		return (ENOTSUP);
	if ((kn->kn_sfflags & MACH_RCV_MSG) != 0 &&
	    kn->kn_kevent.ext[0] != 0 && kn->kn_kevent.ext[1] != 0)
		return (ENOTSUP);
	note = malloc(sizeof(*note), M_MACH_IPC_ENTRY, M_WAITOK | M_ZERO);
	is_read_lock(space);
	entry = ipc_entry_lookup(space, (mach_port_name_t)kn->kn_kevent.ident);
	if (entry == IE_NULL || entry->ie_fp != kn->kn_fp ||
	    (entry->ie_bits & MACH_PORT_TYPE_PORT_SET) == 0) {
		is_read_unlock(space);
		free(note, M_MACH_IPC_ENTRY);
		return (ENOENT);
	}
	note->entry = entry;
	note->pset = (ipc_pset_t)entry->ie_object;
	ipc_entry_reference(entry);
	ips_reference(note->pset);
	is_read_unlock(space);
	kn->kn_hook = note;
	knlist_add(&note->pset->ips_note, kn, 0);
	return (0);
}


static void
filt_machportdetach(struct knote *kn)
{
	struct machport_note *note = kn->kn_hook;

	knlist_remove(&note->pset->ips_note, kn, 0);
	ips_release(note->pset);
	ipc_entry_put(note->entry);
	free(note, M_MACH_IPC_ENTRY);
	kn->kn_hook = NULL;
}


static int
filt_machport(struct knote *kn, long hint __unused)
{
	struct machport_note *note = kn->kn_hook;
	uint64_t snapshot;

	/* A coherent hint, not a reservation. No Mach locks or thread state. */
	snapshot = atomic_load_acq_64(&note->pset->ips_ready_snapshot);
	kn->kn_data = (snapshot >> 32) != 0 ? (uint32_t)snapshot : 0;
	kn->kn_fflags = 0;
	bzero(kn->kn_kevent.ext, sizeof(kn->kn_kevent.ext));
	return ((snapshot >> 32) != 0);
}

#if	MACH_KDB
#include <mach_kdb.h>

#include <ddb/db_output.h>

#define	printf	kdbprintf

int
ipc_list_count(
	struct ipc_kmsg *base)
{
	register int count = 0;

	if (base) {
		struct ipc_kmsg *kmsg = base;

		++count;
		while (kmsg && kmsg->ikm_next != base
			    && kmsg->ikm_next != IKM_BOGUS){
			kmsg = kmsg->ikm_next;
			++count;
		}
	}
	return(count);
}

/*
 *	Routine:	ipc_pset_print
 *	Purpose:
 *		Pretty-print a port set for kdb.
 */

void
ipc_pset_print(
	ipc_pset_t	pset)
{
	extern int indent;

	printf("pset 0x%x\n", pset);

	indent += 2;

	ipc_object_print(&pset->ips_object);
	iprintf("local_name = 0x%x\n", pset->ips_local_name);
	iprintf("%d kmsgs => 0x%x",
		ipc_list_count(pset->ips_messages.imq_messages.ikmq_base),
		pset->ips_messages.imq_messages.ikmq_base);
	printf(",rcvrs = 0x%x\n", pset->ips_messages.imq_threads.ithq_base);

	indent -=2;
}

#endif	/* MACH_KDB */
