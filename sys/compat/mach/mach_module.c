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

#include <sys/param.h>
#include <sys/event.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/sysent.h>
#include <sys/sysproto.h>
#include <sys/types.h>
#include <sys/systm.h>
#include <sys/proc.h>
#include <sys/mach/task.h>
#include <sys/mach/ipc/ipc_entry.h>
#include <sys/mach/ipc/ipc_port.h>
#include <sys/mach/ipc/ipc_space.h>


int mach_debug_enable;
static unsigned int mach_current_task_port_name;

SYSCTL_ROOT_NODE(OID_AUTO,  mach, CTLFLAG_RW, 0,
	"mach subsystem parameters");

SYSCTL_INT(_mach, OID_AUTO, debug_enable, CTLFLAG_RWTUN,
		   &mach_debug_enable, 0, "enable mach debug logging");

SYSCTL_UINT(_mach, OID_AUTO, current_task_port_name, CTLFLAG_RWTUN,
    &mach_current_task_port_name, 0,
    "current task Mach port name targeted by mach.current_task_port_status");

static int
sysctl_mach_current_task_space_stats(SYSCTL_HANDLER_ARGS)
{
	char buf[192];
	struct proc *p;
	task_t task;
	ipc_space_t space;
	ipc_entry_num_t tsize, tree_total, table_next;
	unsigned int inuse, recv, send, send_once, pset, dead;
	ipc_entry_t entry;

	p = curthread != NULL ? curthread->td_proc : NULL;
	task = p != NULL ? p->p_machdata : TASK_NULL;
	if (task == TASK_NULL || (space = task->itk_space) == IS_NULL) {
		strlcpy(buf, "status=unavailable reason=no_space", sizeof(buf));
		return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
	}

	inuse = recv = send = send_once = pset = dead = 0;
	table_next = 0;
	tree_total = 0;

	is_read_lock(space);
	if (!space->is_active) {
		is_read_unlock(space);
		strlcpy(buf, "status=unavailable reason=inactive", sizeof(buf));
		return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
	}

	tsize = space->is_table_size;
	tree_total = space->is_tree_total;
	if (space->is_table_next != NULL)
		table_next = space->is_table_next->its_size;
	is_read_unlock(space);

	PROC_LOCK(p);
	LIST_FOREACH(entry, &space->is_entry_list, ie_space_link) {
		ipc_entry_bits_t bits;
		mach_port_type_t type;

		bits = entry->ie_bits;
		type = IE_BITS_TYPE(bits);
		if (type == MACH_PORT_TYPE_NONE)
			continue;

		inuse++;
		if (type & MACH_PORT_TYPE_RECEIVE)
			recv++;
		if (type & MACH_PORT_TYPE_SEND)
			send++;
		if (type & MACH_PORT_TYPE_SEND_ONCE)
			send_once++;
		if (type & MACH_PORT_TYPE_PORT_SET)
			pset++;
		if (type & MACH_PORT_TYPE_DEAD_NAME)
			dead++;
	}
	PROC_UNLOCK(p);

	snprintf(buf, sizeof(buf),
	    "status=ok table=%u next=%u tree=%u inuse=%u recv=%u send=%u send_once=%u pset=%u dead=%u",
	    (unsigned int)tsize, (unsigned int)table_next, (unsigned int)tree_total,
	    inuse, recv, send, send_once, pset, dead);
	return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
}

SYSCTL_PROC(_mach, OID_AUTO, current_task_space_stats,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE, 0, 0,
    sysctl_mach_current_task_space_stats, "A",
    "current task Mach space statistics");

static int
sysctl_mach_current_task_port_status(SYSCTL_HANDLER_ARGS)
{
	char buf[320];
	struct proc *p;
	task_t task;
	ipc_space_t space;
	ipc_entry_t entry;
	ipc_object_t object;
	ipc_port_t port;
	mach_port_name_t name;
	mach_port_type_t type;
	unsigned int entry_refs, active, refs, srights, sorights, mscount, msgcount;
	unsigned int nsrequest, receiver_current, receiver_name;

	p = curthread != NULL ? curthread->td_proc : NULL;
	task = p != NULL ? p->p_machdata : TASK_NULL;
	if (task == TASK_NULL || (space = task->itk_space) == IS_NULL) {
		strlcpy(buf, "status=unavailable reason=no_space", sizeof(buf));
		return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
	}

	name = (mach_port_name_t)mach_current_task_port_name;
	if (!MACH_PORT_NAME_VALID(name)) {
		strlcpy(buf, "status=unavailable reason=no_name", sizeof(buf));
		return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
	}

	entry = ipc_entry_lookup(space, name);
	if (entry == IE_NULL) {
		snprintf(buf, sizeof(buf),
		    "status=unavailable reason=lookup_failed name=%u",
		    name);
		return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
	}

	type = IE_BITS_TYPE(entry->ie_bits);
	entry_refs = ipc_entry_refs(entry);
	object = entry->ie_object;
	if (object == IO_NULL || io_otype(object) != IOT_PORT) {
		snprintf(buf, sizeof(buf),
		    "status=unavailable reason=not_port name=%u type=0x%x entry_refs=%u",
		    name, type, entry_refs);
		return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
	}

	port = (ipc_port_t)object;
	ip_lock(port);
	active = ip_active(port) ? 1U : 0U;
	refs = port->ip_references;
	srights = port->ip_srights;
	sorights = port->ip_sorights;
	mscount = port->ip_mscount;
	msgcount = port->ip_msgcount;
	nsrequest = port->ip_nsrequest != IP_NULL;
	receiver_current = port->ip_receiver == space;
	receiver_name = port->ip_receiver_name;
	ip_unlock(port);

	snprintf(buf, sizeof(buf),
	    "status=ok name=%u type=0x%x entry_refs=%u active=%u refs=%u srights=%u sorights=%u mscount=%u msgcount=%u nsrequest=%u receiver_current=%u receiver_name=%u",
	    name, type, entry_refs, active, refs, srights, sorights, mscount,
	    msgcount, nsrequest, receiver_current, receiver_name);
	return (sysctl_handle_string(oidp, buf, sizeof(buf), req));
}

SYSCTL_PROC(_mach, OID_AUTO, current_task_port_status,
    CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_MPSAFE, 0, 0,
    sysctl_mach_current_task_port_status, "A",
    "current task Mach port object status for mach.current_task_port_name");


extern struct filterops machport_filtops;

static struct syscall_helper_data osx_syscalls[] = {
	SYSCALL_INIT_HELPER(__proc_info),
	SYSCALL_INIT_HELPER(__iopolicysys),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_vm_allocate_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_vm_deallocate_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_vm_protect_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_vm_map_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_allocate_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_destroy_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_deallocate_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_mod_refs_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_move_member_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_insert_right_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_insert_member_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_extract_member_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_construct_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_destruct_trap),
	SYSCALL_INIT_HELPER(mach_reply_port),
	SYSCALL_INIT_HELPER(thread_self_trap),
	SYSCALL_INIT_HELPER(task_self_trap),
	SYSCALL_INIT_HELPER(host_self_trap),
	SYSCALL_INIT_HELPER(mach_msg_trap),
	SYSCALL_INIT_HELPER(mach_msg_overwrite_trap),
	SYSCALL_INIT_HELPER(semaphore_signal_trap),
	SYSCALL_INIT_HELPER(semaphore_signal_all_trap),
	SYSCALL_INIT_HELPER(semaphore_signal_thread_trap),
	SYSCALL_INIT_HELPER(semaphore_wait_trap),
	SYSCALL_INIT_HELPER(semaphore_wait_signal_trap),
	SYSCALL_INIT_HELPER(semaphore_timedwait_trap),
	SYSCALL_INIT_HELPER(semaphore_timedwait_signal_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_guard_trap),
	SYSCALL_INIT_HELPER(_kernelrpc_mach_port_unguard_trap),
	SYSCALL_INIT_HELPER(task_name_for_pid),
	SYSCALL_INIT_HELPER(task_for_pid),
	SYSCALL_INIT_HELPER(pid_for_task),
	SYSCALL_INIT_HELPER(macx_swapon),
	SYSCALL_INIT_HELPER(macx_swapoff),
	SYSCALL_INIT_HELPER(macx_triggers),
	SYSCALL_INIT_HELPER(macx_backing_store_suspend),
	SYSCALL_INIT_HELPER(macx_backing_store_recovery),
	SYSCALL_INIT_HELPER(swtch_pri),
	SYSCALL_INIT_HELPER(swtch),
	SYSCALL_INIT_HELPER(thread_switch),
	SYSCALL_INIT_HELPER(clock_sleep_trap),
	SYSCALL_INIT_HELPER(mach_timebase_info),
	SYSCALL_INIT_HELPER(mach_wait_until),
	SYSCALL_INIT_HELPER(mk_timer_create),
	SYSCALL_INIT_HELPER(mk_timer_destroy),
	SYSCALL_INIT_HELPER(mk_timer_arm),
	SYSCALL_INIT_HELPER(mk_timer_cancel),
	SYSCALL_INIT_LAST
};

static int
mach_mod_init(void)
{
	int err;

	if (!cold) {
		printf("mach services can only be loaded at boot time\n");
		return (EINVAL);
	}

	if ((err = syscall_helper_register(osx_syscalls, SY_THR_STATIC_KLD))) {
		printf("failed to register osx calls: %d\n", err);
		return (EINVAL);
	}
	if (kqueue_add_filteropts(EVFILT_MACHPORT, &machport_filtops)) {
		printf("failed to register machport_filtops\n");
		return (EINVAL);
	}
	return (0);
}

static int
mach_module_event_handler(module_t mod, int what, void *arg)
{
	int err;

	switch (what) {
	case MOD_LOAD:
		if ((err = mach_mod_init()) != 0) {
			printf("mach services failed to load - mach system calls will not be available\n");
			return (err);
		}
		break;
	case MOD_UNLOAD:
		return (EBUSY);
	default:
		return (EOPNOTSUPP);
	}
	printf("mach services loaded - mach system calls available\n");
	return (0);
}

static moduledata_t mach_moduledata = {
	"mach",
	mach_module_event_handler,
	NULL
};

DECLARE_MODULE(mach, mach_moduledata, SI_SUB_KLD, SI_ORDER_ANY);
