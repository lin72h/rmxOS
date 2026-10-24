/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 rmxOS contributors
 * All rights reserved.
 */

/* Platform diagnostics must not enter libasl, libnotify, or libdispatch.
 * Use the same ASL Mach wire protocol as asl_private.c, with per-call ports
 * and one nonblocking log send. No heap allocation or shared initialization.
 */
#include <sys/types.h>
#include <sys/time.h>
#include <sys/mach/message.h>
#include <sys/mach/ndr.h>
#include <sys/mach/task_special_ports.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

#include <string.h>
#include <unistd.h>
#include <_simple.h>

extern mach_port_t __sys_task_self_trap(void);
extern mach_port_t __sys_mach_reply_port(void);
extern int __sys__kernelrpc_mach_port_deallocate_trap(mach_port_t, mach_port_t);
extern int __sys__kernelrpc_mach_port_destroy_trap(mach_port_t, mach_port_t);
extern mach_msg_return_t __sys_mach_msg_trap(mach_msg_header_t *, mach_msg_option_t,
    mach_msg_size_t, mach_msg_size_t, mach_port_t, mach_msg_timeout_t, mach_port_t);

static const NDR_record_t simple_ndr = { 0, 0, 0, 0, 1, 0, 0, 0 };

#pragma pack(push, 4)
struct simple_port_reply {
	mach_msg_header_t head;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t port;
	unsigned char trailer[256];
};
struct simple_lookup {
	mach_msg_header_t head;
	NDR_record_t ndr;
	char name[128];
	int target;
	unsigned char instance[16];
	uint64_t flags;
};
struct simple_log {
	mach_msg_header_t head;
	mach_msg_body_t body;
	mach_msg_ool_descriptor_t bytes;
	NDR_record_t ndr;
	mach_msg_type_number_t count;
};
#pragma pack(pop)

static mach_port_t
simple_rpc(mach_msg_header_t *request, size_t size, mach_port_t destination,
    mach_port_t reply, int id)
{
	struct simple_port_reply response = {0};
	mach_msg_return_t kr;

	request->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
	    MACH_MSG_TYPE_MAKE_SEND_ONCE);
	request->msgh_remote_port = destination;
	request->msgh_local_port = reply;
	request->msgh_size = size;
	request->msgh_id = id;
	kr = __sys_mach_msg_trap(request, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
	    size, 0, 0, 100, 0);
	if (kr != MACH_MSG_SUCCESS)
		return (MACH_PORT_NULL);
	kr = __sys_mach_msg_trap(&response.head, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
	    0, sizeof(response), reply, 100, 0);
	if (kr != MACH_MSG_SUCCESS || response.head.msgh_id != id + 100 ||
	    !(response.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
	    response.head.msgh_size != sizeof(mach_msg_header_t) +
	    sizeof(mach_msg_body_t) + sizeof(mach_msg_port_descriptor_t) ||
	    response.body.msgh_descriptor_count != 1 ||
	    response.port.type != MACH_MSG_PORT_DESCRIPTOR ||
	    response.port.disposition != MACH_MSG_TYPE_PORT_SEND)
		return (MACH_PORT_NULL);
	return (response.port.name);
}

static void
simple_send(const char *record)
{
	struct {
		mach_msg_header_t head;
		NDR_record_t ndr;
		int which;
	} special = { .ndr = simple_ndr, .which = TASK_BOOTSTRAP_PORT };
	struct simple_lookup lookup = { .ndr = simple_ndr };
	struct simple_log request = {0};
	mach_port_t task, reply, bootstrap = MACH_PORT_NULL, server = MACH_PORT_NULL;
	size_t length;

	task = __sys_task_self_trap();
	reply = __sys_mach_reply_port();
	if (reply == MACH_PORT_NULL)
		return;
	bootstrap = simple_rpc(&special.head, sizeof(special), task, reply, 3409);
	if (bootstrap == MACH_PORT_NULL)
		goto out;
	strlcpy(lookup.name, "com.apple.system.logger", sizeof(lookup.name));
	server = simple_rpc(&lookup.head, sizeof(lookup), bootstrap, reply, 404);
	if (server == MACH_PORT_NULL)
		goto out;
	length = strlen(record) + 1;
	request.head.msgh_bits = MACH_MSGH_BITS_COMPLEX |
	    MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
	request.head.msgh_remote_port = server;
	request.head.msgh_id = 118;
	request.head.msgh_size = sizeof(request);
	request.body.msgh_descriptor_count = 1;
	request.bytes.address = (void *)(uintptr_t)record;
	request.bytes.size = length;
	request.bytes.copy = MACH_MSG_VIRTUAL_COPY;
	request.bytes.type = MACH_MSG_OOL_DESCRIPTOR;
	request.ndr = simple_ndr;
	request.count = length;
	(void)__sys_mach_msg_trap(&request.head, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
	    sizeof(request), 0, 0, 0, 0);
out:
	if (server != MACH_PORT_NULL)
		(void)__sys__kernelrpc_mach_port_deallocate_trap(task, server);
	if (bootstrap != MACH_PORT_NULL)
		(void)__sys__kernelrpc_mach_port_deallocate_trap(task, bootstrap);
	/* Per-call receive rights also discard any late RPC reply. */
	(void)__sys__kernelrpc_mach_port_destroy_trap(task, reply);
}

static int
simple_field(char *record, size_t capacity, size_t *length, const char *key,
    const char *value)
{
	int n;
	unsigned char ch;

	n = snprintf(record + *length, capacity - *length, "[%s ", key);
	if (n < 0 || (size_t)n >= capacity - *length)
		return (-1);
	*length += n;
	while ((ch = *value++) != '\0') {
		if (capacity - *length < 3)
			return (-1);
		if (ch == '\\' || ch == '[' || ch == ']' || ch == '\n' || ch == '\r')
			record[(*length)++] = '\\';
		record[(*length)++] = ch == '\n' ? 'n' : ch == '\r' ? 'r' : ch;
	}
	if (capacity - *length < 3)
		return (-1);
	record[(*length)++] = ']';
	record[(*length)++] = ' ';
	record[*length] = '\0';
	return (0);
}

void
_simple_asl_log_prog(int level, const char *facility, const char *message,
    const char *progname)
{
	char record[2048], host[256];
	struct timeval tv;
	size_t length;
	int n, saved_errno;

	saved_errno = errno;
	if (message == NULL || level < 0 || level > 7)
		goto out;
	if (gettimeofday(&tv, NULL) != 0)
		goto out;
	if (gethostname(host, sizeof(host)) != 0)
		host[0] = '\0';
	host[sizeof(host) - 1] = '\0';
	n = snprintf(record, sizeof(record), "[Level %d] [PID %d] [Time %jd] "
	    "[TimeNanoSec %ld] ", level, getpid(), (intmax_t)tv.tv_sec,
	    tv.tv_usec * 1000);
	if (n < 0 || (size_t)n >= sizeof(record))
		goto out;
	length = n;
	if (simple_field(record, sizeof(record), &length, "Sender",
	    progname != NULL ? progname : "") != 0 ||
	    simple_field(record, sizeof(record), &length, "Facility",
	    facility != NULL ? facility : "user") != 0 ||
	    simple_field(record, sizeof(record), &length, "Host", host) != 0 ||
	    simple_field(record, sizeof(record), &length, "Message", message) != 0)
		goto out;
	simple_send(record);
out:
	errno = saved_errno;
}

void
_simple_asl_log(int level, const char *facility, const char *message)
{

	_simple_asl_log_prog(level, facility, message, getprogname());
}
