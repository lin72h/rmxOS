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
 * Mach Operating System
 * Copyright (c) 1991,1990,1989,1988 Carnegie Mellon University
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
 *	File:	kern/task.c
 *	Author:	Avadis Tevanian, Jr., Michael Wayne Young, David Golub,
 *		David Black
 *
 *	Task management primitives implementation.
 */
/*
 * Copyright (c) 1993 The University of Utah and
 * the Computer Systems Laboratory (CSL).  All rights reserved.
 *
 * Permission to use, copy, modify and distribute this software and its
 * documentation is hereby granted, provided that both the copyright
 * notice and this permission notice appear in all copies of the
 * software, derivative works or modified versions, and any portions
 * thereof, and that both notices appear in supporting documentation.
 *
 * THE UNIVERSITY OF UTAH AND CSL ALLOW FREE USE OF THIS SOFTWARE IN ITS "AS
 * IS" CONDITION.  THE UNIVERSITY OF UTAH AND CSL DISCLAIM ANY LIABILITY OF
 * ANY KIND FOR ANY DAMAGES WHATSOEVER RESULTING FROM THE USE OF THIS SOFTWARE.
 *
 * CSL requests users of this software to return to csl-dist@cs.utah.edu any
 * improvements that they make and grant CSL redistribution rights.
 *
 */

#include <sys/cdefs.h>
#include <sys/types.h>
#include <sys/param.h>
#include <sys/eventhandler.h>
#include <sys/imgact.h>
#include <sys/filedesc.h>
#include <sys/refcount.h>
#include <sys/kernel.h>
#include <sys/mach/vm_types.h>

#include <sys/mach/task_info.h>
#include <sys/mach/task_special_ports.h>
#include <sys/mach/mach_types.h>
#include <sys/mach/rpc.h>
#include <sys/mach/ipc/ipc_space.h>
#include <sys/mach/ipc/ipc_entry.h>
#include <sys/mach/mach_param.h>

#include <sys/mach/task.h>
#include <sys/mach/ipc/ipc_kmsg.h>
#include <sys/mach/thread.h>

#include <sys/mach/sched_prim.h>	/* for thread_wakeup */
#include <sys/mach/ipc_tt.h>
#if 0
#include <sys/mach/ledger.h>
#endif
#include <sys/mach/host_special_ports.h>
#include <sys/mach/host.h>
#include <sys/resourcevar.h>
#include <sys/syscallsubr.h>
#include <vm/vm_extern.h>
#include <vm/vm_kern.h>		/* for kernel_map, ipc_kernel_map */
#include <vm/uma.h>
#if	MACH_KDB
#include <ddb/db_sym.h>
#endif	/* MACH_KDB */

#include <sys/mach/queue.h>
/*
 * Exported interfaces
 */
#include <sys/mach/task_server.h>
#include <sys/mach/mach_host_server.h>
#include <sys/mach/mach_port_server.h>

struct processor_set default_pset;
unsigned	int sched_ticks;
task_t	kernel_task;
uma_zone_t	task_zone;

/* Forwards */


kern_return_t	task_hold_locked(
			task_t		task);
void		task_wait_locked(
			task_t		task);
kern_return_t	task_release(
			task_t		task);
void		task_act_iterate(
			task_t		 task,
			kern_return_t	(*func)(thread_act_t inc));
void		task_free(
			task_t		task );
void		task_synchronizer_destroy_all(
			task_t		task);


kern_return_t
task_create(
	task_t				parent_task,
	__unused ledger_array_t	ledger_ports,
	__unused mach_msg_type_number_t	num_ledger_ports,
	__unused boolean_t		inherit_memory,
	__unused task_t			*child_task)	/* OUT */
{
	if (parent_task == TASK_NULL)
		return(KERN_INVALID_ARGUMENT);

	return(KERN_FAILURE);
}


/*
 *	task_free:
 *
 *	Called by task_deallocate when the task's reference count drops to zero.
 *	No native binding or IPC lock is held by the releasing caller.
 */
void
mach_space_drop(ipc_space_t space)
{
	if (space == IS_NULL)
		return;
	if (refcount_release(&space->is_owners))
		ipc_space_destroy(space);
	is_release(space);
}

void
task_free(task_t task)
{
	KASSERT(task->itk_p == NULL && task->itk_self == IP_NULL,
	    ("freeing a bound Mach task"));
	mach_space_drop(task->itk_space);
	mach_space_drop(task->itk_exec_space);
	mtx_destroy(&task->itk_binding_lock);
	mtx_destroy(&task->itk_lock_data);
	mtx_destroy(&task->lock);
	uma_zfree(task_zone, task);
}

void
task_deallocate(task_t task)
{
	if (task != TASK_NULL && refcount_release((u_int *)&task->ref_count))
		task_free(task);
}

void
task_reference(task_t task)
{
	if (task != TASK_NULL)
		refcount_acquire((u_int *)&task->ref_count);
}


/*
 *	task_terminate:
 *
 *	Terminate the specified task.  See comments on thread_terminate
 *	(kern/thread.c) about problems with terminating the "current task."
 */
kern_return_t
task_terminate(
	register task_t	task)
{
#ifdef notyet	
	register thread_t	thread, cur_thread;
#if 0
	register queue_head_t	*list;
#endif	
	register task_t		cur_task;
	thread_act_t		thr_act, cur_thr_act;

	if (task == TASK_NULL)
		return(KERN_INVALID_ARGUMENT);

	assert(task != kernel_task);
#if 0
	list = &task->thr_acts;
	cur_task = current_task();
	cur_thr_act = current_thread()->top_act;
#endif

	/*
	 *	Deactivate task so that it can't be terminated again,
	 *	and so lengthy operations in progress will abort.
	 *
	 *	If the current thread is in this task, remove it from
	 *	the task's thread list to keep the thread-termination
	 *	loop simple.
	 */
	if (task == cur_task) {
		task_lock(task);
		if (!task->active) {
			/*
			 *	Task is already being terminated.
			 */
			task_unlock(task);
			thread_block();
			return(KERN_FAILURE);
		}

		task_hold_locked(task);
#if 0
		task->active = FALSE;

		/*
		 *	Make sure current thread is not being terminated.
		 */
		mutex_lock(&task->act_list_lock);
		cur_thread = act_lock_thread(cur_thr_act);
		if (!cur_thr_act->active) {
			act_unlock_thread(cur_thr_act);
			mutex_unlock(&task->act_list_lock);
			task_unlock(task);
			thread_terminate(cur_thr_act);
			return(KERN_FAILURE);
		}

		/*
		 * make sure that this thread is the last one in the list
		 */
		queue_remove(list, cur_thr_act, thread_act_t, thr_acts);
		queue_enter(list, cur_thr_act, thread_act_t, thr_acts);
		act_unlock_thread(cur_thr_act);
		mutex_unlock(&task->act_list_lock);
		/*
		 *	Shut down this thread's ipc now because it must
		 *	be left alone to terminate the task.
		 */
		ipc_thr_act_disable(cur_thr_act);
		ipc_thr_act_terminate(cur_thr_act);
#endif
	}
	else {
		/*
		 *	Lock both current and victim task to check for
		 *	potential deadlock.
		 */
		if (task < cur_task) {
			task_lock(task);
			task_lock(cur_task);
		}
		else {
			task_lock(cur_task);
			task_lock(task);
		}
		/*
		 *	Check if current thread_act or task is being terminated.
		 */
		cur_thread = act_lock_thread(cur_thr_act);
		if ((!cur_task->active) || (!cur_thr_act->active)) {
			/*
			 * Current task or thread is being terminated.
			 */
			act_unlock_thread(cur_thr_act);
			task_unlock(task);
			task_unlock(cur_task);
			return(KERN_FAILURE);
		}
		act_unlock_thread(cur_thr_act);
		task_unlock(cur_task);

		if (!task->active) {
			/*
			 *	Task is already being terminated.
			 */
			task_unlock(task);
			thread_block();
			return(KERN_FAILURE);
		}
		task_hold_locked(task);
		task->active = FALSE;
	}

	/*
	 *	Prevent further execution of the task.  ipc_task_disable
	 *	prevents further task operations via the task port.
	 *	If this is the current task, the current thread will
	 *	be left running.
	 */
	ipc_task_disable(task);
	task_wait_locked(task);

	/*
	 *	Terminate each thread in the task.  Depending on the
	 *	state of the thread, this can mean a number of things.
	 *	However, we just call thread_terminate(), which
	 *	takes care of all cases (see that code for details).
	 *
         *      The task_port is closed down, so no more thread_create
         *      operations can be done.  Thread_terminate closes the
         *      thread port for each thread; when that is done, the
         *      thread will eventually disappear.  Thus the loop will
         *      terminate.
	 *	Need to call thread_block() inside loop because some
         *      other thread (e.g., the reaper) may have to run to get rid
         *      of all references to the thread; it won't vanish from
         *      the task's thread list until the last one is gone.
         */
        while (!queue_empty(list)) {
                thr_act = (thread_act_t) queue_first(list);
                act_reference(thr_act);
                task_unlock(task);
                thread_terminate(thr_act);
                act_deallocate(thr_act);
                task_lock(task);
        }
        task_unlock(task);
#endif
	/*
	 *	Destroy all synchronizers owned by the task.
	 */
	task_synchronizer_destroy_all(task);

	/*
	 *	Shut down IPC.
	 */
	ipc_task_terminate(task);
	/* The IPC binding owns and releases the former alive reference. */
	return(KERN_SUCCESS);
}

/*
 *	task_hold_locked:
 *
 *	Suspend execution of the specified task.
 *	This is a recursive-style suspension of the task, a count of
 *	suspends is maintained.
 *
 * 	CONDITIONS: the task is locked.
 */
kern_return_t
task_hold_locked(
	register task_t	task)
{
#if 0
	register queue_head_t	*list;
	register thread_act_t	thr_act, cur_thr_act;

	cur_thr_act = current_act();
#endif	

	if (!task->active) {
		return(KERN_FAILURE);
	}
#if 0

	task->suspend_count++;
	/*
	 *	Iterate through all the thread_act's and hold them.
	 *	Do not hold the current thread_act if it is within the
	 *	task.
	 */
	list = &task->thr_acts;
	thr_act = (thread_act_t) queue_first(list);
	while (!queue_end(list, (queue_entry_t) thr_act)) {
		(void)act_lock_thread(thr_act);
		thread_hold(thr_act);
		act_unlock_thread(thr_act);
		thr_act = (thread_act_t) queue_next(&thr_act->thr_acts);
	}
#endif	
	return(KERN_SUCCESS);
}


kern_return_t
task_release(
	register task_t	task)
{
#if 0
	register queue_head_t	*list;
	register thread_act_t	thr_act, next;

	task_lock(task);
	if (!task->active) {
		task_unlock(task);
		return(KERN_FAILURE);
	}

	task->suspend_count--;

	/*
	 *	Iterate through all the thread_act's and release them.
	 */
	list = &task->thr_acts;
	thr_act = (thread_act_t) queue_first(list);
	while (!queue_end(list, (queue_entry_t) thr_act)) {
		next = (thread_act_t) queue_next(&thr_act->thr_acts);
		(void)act_lock_thread(thr_act);
		thread_release(thr_act);
		act_unlock_thread(thr_act);
		thr_act = next;
	}
	task_unlock(task);
#endif	
	return(KERN_SUCCESS);
}

kern_return_t
task_threads(
	task_t			task,
	thread_act_array_t	*thr_act_list,
	mach_msg_type_number_t	*count)
{
	*thr_act_list = NULL;
	*count = 0;
	if (task == TASK_NULL)
		return (KERN_INVALID_ARGUMENT);
	return (KERN_NOT_SUPPORTED);
}

kern_return_t
task_suspend(
	register task_t		task)
{
#if 0
	if (task == TASK_NULL)
		return (KERN_INVALID_ARGUMENT);

	task_lock(task);
	if (!task->active) {
		task_unlock(task);
		return (KERN_FAILURE);
	}
	if ((task->user_stop_count)++ > 0) {
		/*
		 *	If the stop count was positive, the task is
		 *	already stopped and we can exit.
		 */
		task_unlock(task);
		return (KERN_SUCCESS);
	}

	/*
	 *	Hold all of the threads in the task, and wait for
	 *	them to stop.  If the current thread is within
	 *	this task, hold it separately so that all of the
	 *	other threads can stop first.
	 */
	if (task_hold_locked(task) != KERN_SUCCESS) {
		task_unlock(task);
		return (KERN_FAILURE);
	}

	task_wait_locked(task);
	task_unlock(task);
#endif
	return (KERN_SUCCESS);
}

/*
 * Wait for all threads in task to stop.  Called with task locked.
 */
void
task_wait_locked(
	register task_t		task)
{
	#if 0
	register queue_head_t	*list;
	register thread_act_t	thr_act, refd_thr_act;
	register thread_t	thread, cur_thr;

	cur_thr = current_thread();
	/*
	 *	Iterate through all the thread's and wait for them to
	 *	stop.  Do not wait for the current thread if it is within
	 *	the task.
	 */
	list = &task->thr_acts;
	refd_thr_act = THR_ACT_NULL;
	while (1) {
		thr_act = (thread_act_t) queue_first(list);
		while (!queue_end(list, (queue_entry_t) thr_act)) {
			thread = act_lock_thread(thr_act);
			if (refd_thr_act != THR_ACT_NULL) {
				act_deallocate(refd_thr_act);
				refd_thr_act = THR_ACT_NULL;
			}
			if (thread &&
				thr_act == thread->top_act && thread != cur_thr) {
				refd_thr_act = thr_act;
				act_locked_act_reference(thr_act);
				act_unlock_thread(thr_act);
				task_unlock(task);
				(void)thread_wait(thread);
				task_lock(task);
				thread = act_lock_thread(thr_act);
				if (!thr_act->active) {
					act_unlock_thread(thr_act);
					break;
				}
			}
			act_unlock_thread(thr_act);
			thr_act = (thread_act_t) queue_next(&thr_act->thr_acts);
		}
	    	if (queue_end(list, (queue_entry_t)thr_act))
			break;
	}
	if (refd_thr_act != THR_ACT_NULL) {
		act_deallocate(refd_thr_act);
		refd_thr_act = THR_ACT_NULL;
	}
#endif
}

kern_return_t 
task_resume(register task_t task)
{
	register boolean_t	release;

	if (task == TASK_NULL)
		return(KERN_INVALID_ARGUMENT);

	release = FALSE;
#if 0	
	task_lock(task);
	if (!task->active) {
		task_unlock(task);
		return(KERN_FAILURE);
	}
	if (task->user_stop_count > 0) {
		if (--(task->user_stop_count) == 0)
	    		release = TRUE;
	}
	else {
		task_unlock(task);
		return(KERN_FAILURE);
	}
	task_unlock(task);
#endif
	/*
	 *	Release the task if necessary.
	 */
	if (release)
		return(task_release(task));

	return(KERN_SUCCESS);
}

kern_return_t
task_set_info(
	task_t		task,
	task_flavor_t	flavor,
	task_info_t	task_info_in __unused,		/* pointer to IN array */
	mach_msg_type_number_t	task_info_count __unused)
{

	if (task == TASK_NULL)
		return(KERN_INVALID_ARGUMENT);

	switch (flavor) {
	    default:
			return (KERN_INVALID_ARGUMENT);
	}
	return (KERN_SUCCESS);
}

kern_return_t
task_info(
	task_t			task,
	task_flavor_t		flavor,
	task_info_t		task_info_out,
	mach_msg_type_number_t	*task_info_count)
{
	task_basic_info_data_t basic = { 0 };
	struct vmspace *vm;
	struct rusage usage;
	mach_msg_type_number_t capacity = *task_info_count;

	*task_info_count = 0;
	bzero(task_info_out, MIN(capacity, TASK_BASIC_INFO_COUNT) * sizeof(integer_t));
	if (task == TASK_NULL)
		return (KERN_INVALID_ARGUMENT);
	if (task != current_task())
		return (KERN_NOT_SUPPORTED);
	if (flavor != TASK_BASIC_INFO)
		return (flavor == TASK_THREAD_TIMES_INFO ?
		    KERN_NOT_SUPPORTED : KERN_INVALID_ARGUMENT);
	if (capacity < TASK_BASIC_INFO_COUNT)
		return (KERN_INVALID_ARGUMENT);
	if (kern_getrusage(curthread, RUSAGE_SELF, &usage) != 0)
		return (KERN_FAILURE);
	vm = vmspace_acquire_ref(curproc);
	vm_map_lock_read(&vm->vm_map);
	basic.virtual_size = vm->vm_map.size;
	basic.resident_size = pmap_resident_count(vmspace_pmap(vm)) * PAGE_SIZE;
	vm_map_unlock_read(&vm->vm_map);
	vmspace_free(vm);
	basic.user_time.seconds = usage.ru_utime.tv_sec;
	basic.user_time.microseconds = usage.ru_utime.tv_usec;
	basic.system_time.seconds = usage.ru_stime.tv_sec;
	basic.system_time.microseconds = usage.ru_stime.tv_usec;
	task_lock(task);
	basic.policy = task->policy;
	basic.suspend_count = task->user_stop_count;
	task_unlock(task);
	memcpy(task_info_out, &basic, sizeof(basic));
	*task_info_count = TASK_BASIC_INFO_COUNT;
	return (KERN_SUCCESS);
}

/*
 *	task_assign:
 *
 *	Change the assigned processor set for the task
 */
kern_return_t
task_assign(
	task_t				task __unused,
	processor_set_t			new_pset __unused,
	boolean_t			assign_threads __unused)
{

	return (KERN_FAILURE);
}

/*
 *	task_assign_default:
 *
 *	Version of task_assign to assign to default processor set.
 */
kern_return_t
task_assign_default(
	task_t		task,
	boolean_t	assign_threads)
{
    return (task_assign(task, &default_pset, assign_threads));
}

/*
 *	task_get_assignment
 *
 *	Return name of processor set that task is assigned to.
 */
kern_return_t
task_get_assignment(
	task_t		task,
	processor_set_t	*pset)
{
	if (!task->active)
		return(KERN_FAILURE);

	*pset = task->processor_set;
	pset_reference(*pset);
	return(KERN_SUCCESS);
}

/*
 * 	task_policy
 *
 *	Set scheduling policy and parameters, both base and limit, for
 *	the given task. Policy must be a policy which is enabled for the
 *	processor set. Change contained threads if requested. 
 */
kern_return_t
task_policy(
	task_t			task,
        policy_t		policy,
        policy_base_t		base,
	mach_msg_type_number_t	count,
        boolean_t		set_limit,
        boolean_t		change)
{

	return (KERN_FAILURE);
}

kern_return_t
task_set_policy(
	task_t			task __unused,
	processor_set_t		pset __unused,
	policy_t		policy __unused,
	policy_base_t		base __unused,
	mach_msg_type_number_t	base_count __unused,
	policy_limit_t		limit __unused,
	mach_msg_type_number_t	limit_count __unused,
	boolean_t		change __unused)
{

	return (KERN_FAILURE);
}


kern_return_t
task_set_ras_pc(
 	task_t		task __unused,
 	vm_offset_t	pc __unused,
 	vm_offset_t	endpc __unused)
{

	return (KERN_FAILURE);
}

void
task_synchronizer_destroy_all(task_t task)
{
	semaphore_t	semaphore;

	/*
	 *  Destroy owned semaphores
	 */

	while (!queue_empty(&task->semaphore_list)) {
		semaphore = (semaphore_t) queue_first(&task->semaphore_list);
		(void) semaphore_destroy(task, semaphore);
	}
}

static volatile u_long task_uniqueid;

boolean_t
mach_space_is_current(ipc_space_t space)
{
	task_t task = current_task();
	return (task != TASK_NULL && space == task->itk_space &&
	    space->is_fdp == curproc->p_fd);
}

/* Allocate outside the binding mutex; recheck before publishing. */
ipc_space_t
mach_task_space(task_t task)
{
	ipc_space_t space, fresh = IS_NULL, old = IS_NULL;
	struct filedesc *fdp;

	if (task == TASK_NULL)
		return (IS_NULL);
retry:
	mtx_lock(&task->itk_binding_lock);
	fdp = curproc->p_fd;
	space = task->itk_space;
	if (task != current_task() || space->is_fdp == fdp ||
	    task->itk_binding_state != MACH_BIND_ALIVE) {
		mtx_unlock(&task->itk_binding_lock);
		mach_space_drop(fresh);
		return (space);
	}
	if (fresh == IS_NULL) {
		mtx_unlock(&task->itk_binding_lock);
		if (ipc_space_create(&ipc_table_entries[0], &fresh) != KERN_SUCCESS)
			panic("Mach space allocation failed");
		refcount_init(&fresh->is_owners, 1);
		goto retry;
	}
	ipc_entry_space_bind(fresh, fdp);
	old = space;
	task->itk_space = fresh;
	mtx_unlock(&task->itk_binding_lock);
	mach_space_drop(old);
	return (fresh);
}

static void
mach_task_init(void *arg __unused, struct proc *p)
{
	p->p_machdata = NULL;
}

static void
mach_task_ctor(void *arg __unused, struct proc *p)
{
	task_t task;

	task = uma_zalloc(task_zone, M_WAITOK | M_ZERO);
	refcount_init((u_int *)&task->ref_count, 1); /* proc attachment */
	mach_mutex_init(&task->lock, "Mach task");
	mach_mutex_init(&task->itk_lock_data, "Mach task IPC");
	mtx_init(&task->itk_binding_lock, "Mach native binding", NULL, MTX_DEF);
	queue_init(&task->semaphore_list);
	ipc_task_create(task);
	p->p_machdata = task;
	if (p == &proc0) {
		kernel_task = task;
		task->itk_p = p;
		ipc_entry_space_bind(task->itk_space, p->p_fd);
		task->kernel_loaded = TRUE;
		ipc_task_init(task, TASK_NULL);
		task->policy = POLICY_TIMESHARE;
		task->sec_token = KERNEL_SECURITY_TOKEN;
		task->audit_token = KERNEL_AUDIT_TOKEN;
		task->itk_binding_state = MACH_BIND_ALIVE;
		ipc_task_enable(task);
	}
}

static void
mach_task_fork(void *arg __unused, struct proc *p1, struct proc *p2,
    int flags __unused)
{
	task_t parent = p1->p_machdata, task = p2->p_machdata;
	ipc_space_t private;

	(void)mach_task_space(parent);
	task->itk_p = p2;
	task->itk_uniqueid = atomic_fetchadd_long(&task_uniqueid, 1) + 1;
	task->itk_puniqueid = parent->itk_uniqueid;
	if (p1->p_fd == p2->p_fd) {
		mtx_lock(&parent->itk_binding_lock);
		private = task->itk_space;
		task->itk_space = parent->itk_space;
		is_reference(task->itk_space);
		refcount_acquire(&task->itk_space->is_owners);
		mtx_unlock(&parent->itk_binding_lock);
		mach_space_drop(private);
	} else {
		ipc_entry_space_bind(task->itk_space, p2->p_fd);
	}
	ipc_task_init(task, parent);
	set_security_token(task);
	task->policy = parent->policy;
	atomic_store_rel_int(&task->itk_binding_state, MACH_BIND_ALIVE);
	ipc_task_enable(task);
	mach_thread_publish(FIRST_THREAD_IN_PROC(p2));
}

static void
mach_task_exit(void *arg __unused, struct proc *p)
{
	task_t task = p->p_machdata;
	struct thread *td;

	if (task == TASK_NULL)
		return;
	mtx_lock(&task->itk_binding_lock);
	atomic_store_rel_int(&task->itk_binding_state, MACH_BIND_DYING);
	task->itk_p = NULL;
	mtx_unlock(&task->itk_binding_lock);
	ipc_task_disable(task);
	ipc_task_terminate(task);
	if (task->itk_exec_thread != NULL) {
		mach_thread_retire(task->itk_exec_thread);
		ipc_thread_terminate(task->itk_exec_thread);
		thread_deallocate(task->itk_exec_thread);
		task->itk_exec_thread = NULL;
	}
	/* Failed process creation can precede the first native thread. */
	td = FIRST_THREAD_IN_PROC(p);
	if (td != NULL)
		mach_thread_retire(td->td_machdata);
}

static void
mach_task_dtor(void *arg __unused, struct proc *p)
{
	task_t task = p->p_machdata;

	if (task == TASK_NULL)
		return;
	/* Also unwind objects prepared for unsuccessful process creation. */
	mach_task_exit(NULL, p);
	p->p_machdata = NULL;
	task_deallocate(task);
}

static void
mach_task_exec(void *arg __unused, struct proc *p,
    struct image_params *imgp __unused)
{
	task_t task = p->p_machdata;
	ipc_space_t space;

	if (task == TASK_NULL)
		return;
	if (ipc_space_create(&ipc_table_entries[0], &space) != KERN_SUCCESS)
		panic("Mach exec space allocation failed");
	refcount_init(&space->is_owners, 1);
	task->itk_exec_thread = mach_thread_prepare();
	mtx_lock(&task->itk_binding_lock);
	task->itk_exec_space = space;
	atomic_store_rel_int(&task->itk_binding_state, MACH_BIND_EXECING);
	mtx_unlock(&task->itk_binding_lock);
}

static void
mach_task_exec_committed(void *arg __unused, struct proc *p,
    struct image_params *imgp)
{
	task_t task = p->p_machdata;
	ipc_space_t old, fresh;
	thread_t retired;

	if (task == TASK_NULL)
		return;
	old = task->itk_space;
	/* Only the executing process's unshared table may be drained. */
	if (old->is_fdp == p->p_fd)
		ipc_entry_space_close(old);
	mtx_lock(&task->itk_binding_lock);
	fresh = task->itk_exec_space;
	ipc_entry_space_bind(fresh, p->p_fd);
	task->itk_space = fresh;
	task->itk_exec_space = IS_NULL;
	retired = curthread->td_machdata;
	curthread->td_machdata = task->itk_exec_thread;
	task->itk_exec_thread = NULL;
	mtx_unlock(&task->itk_binding_lock);
	mach_thread_retire(retired);
	ipc_thread_terminate(retired);
	retired->ith_td = NULL;
	thread_deallocate(retired); /* old native attachment */
	if (imgp->credential_setid)
		ipc_task_reset_control(task);
	mach_thread_publish(curthread);
	mach_space_drop(old);
	atomic_store_rel_int(&task->itk_binding_state, MACH_BIND_ALIVE);
}

static void
task_sysinit(void *arg __unused)
{
	/* A runtime load is refused by mach_mod_init; publish no callbacks. */
	if (!cold)
		return;
	task_zone = uma_zcreate("mach_task_zone", sizeof(struct mach_task),
	    NULL, NULL, NULL, NULL, UMA_ALIGN_PTR, 0);
	EVENTHANDLER_REGISTER(process_init, mach_task_init, NULL, EVENTHANDLER_PRI_ANY);
	EVENTHANDLER_REGISTER(process_ctor, mach_task_ctor, NULL, EVENTHANDLER_PRI_ANY);
	EVENTHANDLER_REGISTER(process_dtor, mach_task_dtor, NULL, EVENTHANDLER_PRI_ANY);
	EVENTHANDLER_REGISTER(process_fork, mach_task_fork, NULL, EVENTHANDLER_PRI_ANY);
	EVENTHANDLER_REGISTER(process_exit, mach_task_exit, NULL, EVENTHANDLER_PRI_ANY);
	EVENTHANDLER_REGISTER(process_exec, mach_task_exec, NULL, EVENTHANDLER_PRI_ANY);
	EVENTHANDLER_REGISTER(process_exec_committed, mach_task_exec_committed, NULL, EVENTHANDLER_PRI_ANY);
}

/* before SI_SUB_INTRINSIC and after SI_SUB_EVENTHANDLER */
SYSINIT(mach_thread, SI_SUB_KLD, SI_ORDER_ANY, task_sysinit, NULL);
