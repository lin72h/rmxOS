/*
 * Copyright 2014-2015 iXsystems, Inc.
 * All rights reserved
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted providing that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <xpc/xpc.h>
#include <machine/atomic.h>
#include <Block.h>
#include "xpc_internal.h"

#define XPC_CONNECTION_NEXT_ID(conn) (atomic_fetchadd_int(&conn->xc_last_id, 1))

struct xpc_send_context {
	struct xpc_connection *xsc_connection;
	xpc_object_t		xsc_message;
	uint64_t		xsc_id;
};

struct xpc_event_context {
	struct xpc_connection *xec_connection;
	xpc_object_t		xec_event;
	xpc_handler_t		xec_handler;
	mach_port_t		xec_remote_port;
};

static void xpc_connection_recv_message(void *context);
static void xpc_connection_remote_dead(void *context);
static void xpc_connection_remote_proc_dead(void *context);
static void xpc_connection_arm_proc_source(struct xpc_connection *conn);
static bool xpc_connection_cancel_sources(struct xpc_connection *conn);
static void xpc_connection_dispatch_event(struct xpc_connection *conn,
    xpc_object_t event, mach_port_t remote_port);
static void xpc_connection_invoke_event(void *context);
static void xpc_connection_invoke_pending(void *context);
static void xpc_connection_interrupt(struct xpc_connection *conn);
static void xpc_connection_invalidate(struct xpc_connection *conn,
    xpc_object_t error);
static void xpc_connection_resume_all(struct xpc_connection *conn);
static void xpc_connection_send_work(void *context);
static void xpc_connection_source_cancelled(void *context);
static void xpc_send(xpc_connection_t xconn, xpc_object_t message, uint64_t id);

xpc_connection_t
xpc_connection_create(const char *name, dispatch_queue_t targetq)
{
	int error;
	kern_return_t kr;
	char *qname = NULL;
	struct xpc_connection *conn;

	if ((conn = malloc(sizeof(struct xpc_connection))) == NULL) {
		errno = ENOMEM;
		return (NULL);
	}

	memset(conn, 0, sizeof(struct xpc_connection));
	conn->xc_object.xo_xpc_type = _XPC_TYPE_CONNECTION;
	conn->xc_object.xo_refcnt = 1;
	conn->xc_object.xo_size = sizeof(*conn);
	conn->xc_last_id = 1;
	TAILQ_INIT(&conn->xc_peers);
	TAILQ_INIT(&conn->xc_pending);
	if (name != NULL) {
		conn->xc_name = strdup(name);
		if (conn->xc_name == NULL)
			goto nomem;
	}

	/* Create send queue */
	if (asprintf(&qname, "com.ixsystems.xpc.connection.sendq.%p", conn) < 0)
		goto nomem;
	conn->xc_send_queue = dispatch_queue_create(qname, NULL);
	free(qname);
	qname = NULL;
	if (conn->xc_send_queue == NULL)
		goto nomem;

	/* Create recv queue */
	if (asprintf(&qname, "com.ixsystems.xpc.connection.recvq.%p", conn) < 0)
		goto nomem;
	conn->xc_recv_queue = dispatch_queue_create(qname, NULL);
	free(qname);
	qname = NULL;
	if (conn->xc_recv_queue == NULL)
		goto nomem;

	/* Create target queue */
	conn->xc_target_queue = targetq ? targetq : dispatch_get_main_queue();
	dispatch_retain(conn->xc_target_queue);
	dispatch_set_target_queue(conn->xc_recv_queue, conn->xc_target_queue);

	/* Receive queue is initially suspended */
	dispatch_suspend(conn->xc_recv_queue);
	conn->xc_suspend_count = 1;

	/* Create local port */
	kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
	    &conn->xc_local_port);
	if (kr != KERN_SUCCESS) {
		error = EPERM;
		goto fail;
	}
	conn->xc_owns_local_port = true;

	kr = mach_port_insert_right(mach_task_self(), conn->xc_local_port,
	    conn->xc_local_port, MACH_MSG_TYPE_MAKE_SEND);
	if (kr != KERN_SUCCESS) {
		error = EPERM;
		goto fail;
	}

	return (conn);

nomem:
	error = ENOMEM;
fail:
	free(qname);
	xpc_release(conn);
	errno = error;
	return (NULL);
}

xpc_connection_t
xpc_connection_create_mach_service(const char *name, dispatch_queue_t targetq,
    uint64_t flags)
{
	kern_return_t kr;
	struct xpc_connection *conn;

	conn = xpc_connection_create(name, targetq);
	if (conn == NULL)
		return (NULL);

	conn->xc_flags = flags;

	if (flags & XPC_CONNECTION_MACH_SERVICE_LISTENER) {
		if (conn->xc_owns_local_port) {
			(void)mach_port_destroy(mach_task_self(), conn->xc_local_port);
			conn->xc_local_port = MACH_PORT_NULL;
			conn->xc_owns_local_port = false;
		}
		kr = bootstrap_check_in(bootstrap_port, name,
		    &conn->xc_local_port);
		if (kr != KERN_SUCCESS) {
			xpc_release(conn);
			errno = EBUSY;
			return (NULL);
		}
		conn->xc_owns_local_port = true;

		return (conn);	
	}

	if (!strcmp(name, "bootstrap")) {
		conn->xc_remote_port = bootstrap_port;
		return (conn);
	}

	/* Look up named mach service */
	kr = bootstrap_look_up(bootstrap_port, name, &conn->xc_remote_port);
	if (kr != KERN_SUCCESS) {
		xpc_release(conn);
		errno = ENOENT;
		return (NULL);
	}
	conn->xc_owns_remote_port = true;

	return (conn);
}

xpc_connection_t
xpc_connection_create_from_endpoint(xpc_endpoint_t endpoint)
{
	struct xpc_connection *conn;
	struct xpc_object *xo;

	xo = endpoint;
	if (xo == NULL || xo->xo_xpc_type != _XPC_TYPE_ENDPOINT)
		return (NULL);

	conn = xpc_connection_create(NULL, NULL);
	if (conn == NULL)
		return (NULL);

	conn->xc_remote_port = xo->xo_port;
	return (conn);
}

void
xpc_connection_set_target_queue(xpc_connection_t xconn,
    dispatch_queue_t targetq)
{
	struct xpc_connection *conn;
	dispatch_queue_t oldq;

	debugf("connection=%p", xconn);
	conn = xconn;
	targetq = targetq ? targetq : dispatch_get_main_queue();
	dispatch_retain(targetq);
	oldq = conn->xc_target_queue;
	conn->xc_target_queue = targetq;
	dispatch_set_target_queue(conn->xc_recv_queue, targetq);
	if (oldq != NULL)
		dispatch_release(oldq);
}

void
xpc_connection_set_event_handler(xpc_connection_t xconn,
    xpc_handler_t handler)
{
	struct xpc_connection *conn;

	debugf("connection=%p", xconn);
	conn = xconn;
	handler = (xpc_handler_t)Block_copy(handler);
	if (conn->xc_handler != NULL)
		Block_release(conn->xc_handler);
	conn->xc_handler = handler;
}

void
xpc_connection_suspend(xpc_connection_t xconn)
{
	struct xpc_connection *conn;

	conn = xconn;
	if (conn->xc_cancelled)
		return;
	atomic_add_int(&conn->xc_suspend_count, 1);
	dispatch_suspend(conn->xc_recv_queue);
}

void
xpc_connection_resume(xpc_connection_t xconn)
{
	struct xpc_connection *conn;
	u_int count;

	debugf("connection=%p", xconn);
	conn = xconn;
	if (conn->xc_cancelled)
		return;
	for (;;) {
		count = atomic_load_acq_int(&conn->xc_suspend_count);
		if (count == 0)
			return;
		if (atomic_cmpset_int(&conn->xc_suspend_count, count, count - 1))
			break;
	}

	/* Create dispatch sources on the first resume. */
	if (atomic_cmpset_int(&conn->xc_started, 0, 1) &&
	    conn->xc_parent == NULL) {
		conn->xc_recv_source = dispatch_source_create(
		    DISPATCH_SOURCE_TYPE_MACH_RECV, conn->xc_local_port, 0,
		    conn->xc_recv_queue);
		if (conn->xc_recv_source != NULL) {
			dispatch_set_context(conn->xc_recv_source, conn);
			dispatch_source_set_event_handler_f(conn->xc_recv_source,
			    xpc_connection_recv_message);
			dispatch_resume(conn->xc_recv_source);
		}
	}

	if (conn->xc_send_source == NULL && conn->xc_remote_port !=
	    MACH_PORT_NULL) {
		conn->xc_send_source = dispatch_source_create(
		    DISPATCH_SOURCE_TYPE_MACH_SEND, conn->xc_remote_port,
		    DISPATCH_MACH_SEND_DEAD, conn->xc_recv_queue);
		if (conn->xc_send_source != NULL) {
			dispatch_set_context(conn->xc_send_source, conn);
			dispatch_source_set_event_handler_f(conn->xc_send_source,
			    xpc_connection_remote_dead);
			dispatch_resume(conn->xc_send_source);
		}
	}

	dispatch_resume(conn->xc_recv_queue);
}

void
xpc_connection_send_message(xpc_connection_t xconn,
    xpc_object_t message)
{
	struct xpc_connection *conn;
	struct xpc_send_context *send;
	uint64_t id;

	conn = xconn;
	if (conn->xc_cancelled)
		return;
	id = xpc_dictionary_get_uint64(message, XPC_SEQID);

	if (id == 0)
		id = XPC_CONNECTION_NEXT_ID(conn);

	send = malloc(sizeof(*send));
	if (send == NULL)
		return;
	send->xsc_connection = xpc_retain(conn);
	send->xsc_message = xpc_retain(message);
	send->xsc_id = id;
	dispatch_async_f(conn->xc_send_queue, send, xpc_connection_send_work);
}

void
xpc_connection_send_message_with_reply(xpc_connection_t xconn,
    xpc_object_t message, dispatch_queue_t targetq, xpc_handler_t handler)
{
	struct xpc_connection *conn;
	struct xpc_pending_call *call;
	struct xpc_send_context *send;

	conn = xconn;
	if (conn->xc_cancelled)
		return;

	call = calloc(1, sizeof(*call));
	send = malloc(sizeof(*send));
	if (call == NULL || send == NULL) {
		free(call);
		free(send);
		return;
	}
	call->xp_id = XPC_CONNECTION_NEXT_ID(conn);
	call->xp_handler = (xpc_handler_t)Block_copy(handler);
	call->xp_queue = targetq;
	if (call->xp_queue != NULL)
		dispatch_retain(call->xp_queue);
	TAILQ_INSERT_TAIL(&conn->xc_pending, call, xp_link);

	send->xsc_connection = xpc_retain(conn);
	send->xsc_message = xpc_retain(message);
	send->xsc_id = call->xp_id;
	dispatch_async_f(conn->xc_send_queue, send, xpc_connection_send_work);
}

xpc_object_t
xpc_connection_send_message_with_reply_sync(xpc_connection_t conn,
    xpc_object_t message)
{
	struct xpc_connection *xconn;
	__block xpc_object_t result = NULL;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);

	xconn = conn;
	xpc_connection_send_message_with_reply(conn, message, xconn->xc_recv_queue,
	    ^(xpc_object_t o) {
		result = xpc_retain(o);
		dispatch_semaphore_signal(sem);
	});

	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
	dispatch_release(sem);
	return (result);
}

void
xpc_connection_send_barrier(xpc_connection_t xconn, dispatch_block_t barrier)
{
	struct xpc_connection *conn;

	conn = xconn;
	dispatch_sync(conn->xc_send_queue, barrier);
}

void
xpc_connection_cancel(xpc_connection_t connection)
{
	struct xpc_connection *conn;

	conn = connection;
	if (!atomic_cmpset_int(&conn->xc_cancelled, 0, 1))
		return;

	xpc_connection_invalidate(conn, XPC_ERROR_CONNECTION_INVALID);
	(void)xpc_connection_cancel_sources(conn);
}

const char *
xpc_connection_get_name(xpc_connection_t connection)
{
	struct xpc_connection *conn;

	conn = connection;
	return (conn->xc_name);
}

uid_t
xpc_connection_get_euid(xpc_connection_t xconn)
{
	struct xpc_connection *conn;

	conn = xconn;
	return (conn->xc_remote_euid);
}

gid_t
xpc_connection_get_guid(xpc_connection_t xconn)
{
	struct xpc_connection *conn;

	conn = xconn;
	return (conn->xc_remote_guid);
}

pid_t
xpc_connection_get_pid(xpc_connection_t xconn)
{
	struct xpc_connection *conn;

	conn = xconn;
	return (conn->xc_remote_pid);
}

au_asid_t
xpc_connection_get_asid(xpc_connection_t xconn)
{
	struct xpc_connection *conn;

	conn = xconn;
	return (conn->xc_remote_asid);
}

void
xpc_connection_set_context(xpc_connection_t xconn, void *ctx)
{
	struct xpc_connection *conn;

	conn = xconn;
	conn->xc_context = ctx;
}

void *
xpc_connection_get_context(xpc_connection_t xconn)
{
	struct xpc_connection *conn;

	conn = xconn;
	return (conn->xc_context);
}

void
xpc_connection_set_finalizer_f(xpc_connection_t connection,
    xpc_finalizer_t finalizer)
{
	struct xpc_connection *conn;

	conn = connection;
	conn->xc_finalizer = finalizer;
}

xpc_endpoint_t
xpc_endpoint_create(xpc_connection_t connection)
{
	struct xpc_connection *conn;
	xpc_u val;

	conn = connection;
	if (conn == NULL)
		return (NULL);

	val.port = conn->xc_local_port;
	return (_xpc_prim_create(_XPC_TYPE_ENDPOINT, val, 0));
}

void
xpc_main(xpc_connection_handler_t handler)
{

	dispatch_main();
}

void
xpc_transaction_begin(void)
{

}

void
xpc_transaction_end(void)
{

}

static void
xpc_send(xpc_connection_t xconn, xpc_object_t message, uint64_t id)
{
	struct xpc_connection *conn;
	kern_return_t kr;

	debugf("connection=%p, message=%p, id=%d", xconn, message, id);

	conn = xconn;
	kr = xpc_pipe_send(message, conn->xc_remote_port,
	    conn->xc_local_port, id);

	if (kr != KERN_SUCCESS) {
		debugf("send failed, kr=%d", kr);
		xpc_connection_interrupt(conn);
	}
}

static void
xpc_connection_send_work(void *context)
{
	struct xpc_send_context *send;

	send = context;
	if (!send->xsc_connection->xc_cancelled)
		xpc_send(send->xsc_connection, send->xsc_message, send->xsc_id);
	xpc_release(send->xsc_message);
	xpc_release(send->xsc_connection);
	free(send);
}

static void
xpc_connection_invoke_pending(void *context)
{
	struct xpc_pending_call *call;

	call = context;
	if (call->xp_handler != NULL)
		call->xp_handler(call->xp_response);
	if (call->xp_response != NULL)
		xpc_release(call->xp_response);
	if (call->xp_handler != NULL)
		Block_release(call->xp_handler);
	if (call->xp_queue != NULL)
		dispatch_release(call->xp_queue);
	if (call->xp_remote_port != MACH_PORT_NULL)
		(void)mach_port_deallocate(mach_task_self(), call->xp_remote_port);
	free(call);
}

static void
xpc_connection_complete_pending(struct xpc_connection *conn, xpc_object_t error)
{
	struct xpc_pending_call *call;
	dispatch_queue_t queue;

	while ((call = TAILQ_FIRST(&conn->xc_pending)) != NULL) {
		TAILQ_REMOVE(&conn->xc_pending, call, xp_link);
		call->xp_response = xpc_retain(error);
		queue = call->xp_queue ? call->xp_queue : conn->xc_target_queue;
		dispatch_async_f(queue, call, xpc_connection_invoke_pending);
	}
}

static void
xpc_connection_invoke_event(void *context)
{
	struct xpc_event_context *event;

	event = context;
	if (event->xec_handler != NULL)
		event->xec_handler(event->xec_event);
	if (event->xec_handler != NULL)
		Block_release(event->xec_handler);
	xpc_release(event->xec_event);
	if (event->xec_remote_port != MACH_PORT_NULL)
		(void)mach_port_deallocate(mach_task_self(),
		    event->xec_remote_port);
	xpc_release(event->xec_connection);
	free(event);
}

static void
xpc_connection_dispatch_event(struct xpc_connection *conn, xpc_object_t event,
    mach_port_t remote_port)
{
	struct xpc_event_context *delivery;

	if (conn->xc_handler == NULL) {
		if (remote_port != MACH_PORT_NULL)
			(void)mach_port_deallocate(mach_task_self(), remote_port);
		return;
	}

	delivery = malloc(sizeof(*delivery));
	if (delivery == NULL) {
		if (remote_port != MACH_PORT_NULL)
			(void)mach_port_deallocate(mach_task_self(), remote_port);
		return;
	}
	delivery->xec_connection = xpc_retain(conn);
	delivery->xec_event = xpc_retain(event);
	delivery->xec_handler = (xpc_handler_t)Block_copy(conn->xc_handler);
	delivery->xec_remote_port = remote_port;
	dispatch_async_f(conn->xc_recv_queue, delivery,
	    xpc_connection_invoke_event);
}

static void
xpc_connection_deliver_event(struct xpc_connection *conn, xpc_object_t error)
{

	xpc_connection_dispatch_event(conn, error, MACH_PORT_NULL);
}

static void
xpc_connection_invalidate(struct xpc_connection *conn, xpc_object_t error)
{

	xpc_connection_complete_pending(conn, error);
	xpc_connection_deliver_event(conn, error);
}

static void
xpc_connection_interrupt(struct xpc_connection *conn)
{

	if (conn->xc_cancelled)
		return;
	if (!atomic_cmpset_int(&conn->xc_interrupted, 0, 1))
		return;

	xpc_connection_invalidate(conn, XPC_ERROR_CONNECTION_INTERRUPTED);
}

static void
xpc_connection_resume_all(struct xpc_connection *conn)
{
	u_int count;

	if (conn->xc_recv_queue == NULL)
		return;

	for (;;) {
		count = atomic_load_acq_int(&conn->xc_suspend_count);
		if (count == 0)
			break;
		if (!atomic_cmpset_int(&conn->xc_suspend_count, count, count - 1))
			continue;
		dispatch_resume(conn->xc_recv_queue);
	}
}

static void
xpc_connection_source_cancelled(void *context)
{
	struct xpc_connection *conn;

	conn = context;
	if (atomic_fetchadd_int(&conn->xc_source_cancel_count, -1) == 1)
		xpc_release(conn);
}

static bool
xpc_connection_cancel_sources(struct xpc_connection *conn)
{
	dispatch_source_t sources[3];
	u_int count, i;

	xpc_connection_resume_all(conn);
	if (!atomic_cmpset_int(&conn->xc_sources_cancelled, 0, 1))
		return (atomic_load_acq_int(&conn->xc_source_cancel_count) != 0);

	count = 0;
	if (conn->xc_recv_source != NULL) {
		sources[count++] = conn->xc_recv_source;
		conn->xc_recv_source = NULL;
	}
	if (conn->xc_send_source != NULL) {
		sources[count++] = conn->xc_send_source;
		conn->xc_send_source = NULL;
	}
	if (conn->xc_proc_source != NULL) {
		sources[count++] = conn->xc_proc_source;
		conn->xc_proc_source = NULL;
	}
	if (count == 0)
		return (false);

	conn->xc_source_cancel_count = count;
	xpc_retain(conn);
	for (i = 0; i < count; i++) {
		dispatch_source_set_cancel_handler_f(sources[i],
		    xpc_connection_source_cancelled);
		dispatch_source_cancel(sources[i]);
		dispatch_release(sources[i]);
	}

	return (true);
}

void
xpc_connection_destroy(struct xpc_connection *conn)
{
	struct xpc_connection *peer;
	struct xpc_pending_call *call;
	xpc_finalizer_t finalizer;
	void *context;

	if (atomic_cmpset_int(&conn->xc_cancelled, 0, 1))
		xpc_connection_complete_pending(conn,
		    XPC_ERROR_CONNECTION_INVALID);
	if (xpc_connection_cancel_sources(conn))
		return;
	if (atomic_load_acq_int(&conn->xc_source_cancel_count) != 0)
		return;

	while ((call = TAILQ_FIRST(&conn->xc_pending)) != NULL) {
		TAILQ_REMOVE(&conn->xc_pending, call, xp_link);
		if (call->xp_response != NULL)
			xpc_release(call->xp_response);
		if (call->xp_handler != NULL)
			Block_release(call->xp_handler);
		if (call->xp_queue != NULL)
			dispatch_release(call->xp_queue);
		if (call->xp_remote_port != MACH_PORT_NULL)
			(void)mach_port_deallocate(mach_task_self(),
			    call->xp_remote_port);
		free(call);
	}

	while ((peer = TAILQ_FIRST(&conn->xc_peers)) != NULL) {
		TAILQ_REMOVE(&conn->xc_peers, peer, xc_link);
		peer->xc_parent = NULL;
		xpc_connection_cancel(peer);
		xpc_release(peer);
	}

	if (conn->xc_handler != NULL) {
		Block_release(conn->xc_handler);
		conn->xc_handler = NULL;
	}
	if (conn->xc_owns_remote_port &&
	    conn->xc_remote_port != MACH_PORT_NULL) {
		(void)mach_port_deallocate(mach_task_self(), conn->xc_remote_port);
		conn->xc_remote_port = MACH_PORT_NULL;
	}
	if (conn->xc_owns_local_port && conn->xc_local_port != MACH_PORT_NULL) {
		(void)mach_port_destroy(mach_task_self(), conn->xc_local_port);
		conn->xc_local_port = MACH_PORT_NULL;
	}
	if (conn->xc_send_queue != NULL) {
		dispatch_release(conn->xc_send_queue);
		conn->xc_send_queue = NULL;
	}
	if (conn->xc_recv_queue != NULL) {
		dispatch_release(conn->xc_recv_queue);
		conn->xc_recv_queue = NULL;
	}
	if (conn->xc_target_queue != NULL) {
		dispatch_release(conn->xc_target_queue);
		conn->xc_target_queue = NULL;
	}

	free(__DECONST(char *, conn->xc_name));
	conn->xc_name = NULL;
	finalizer = conn->xc_finalizer;
	context = conn->xc_context;
	conn->xc_finalizer = NULL;
	conn->xc_context = NULL;
	if (finalizer != NULL)
		finalizer(context);
	free(conn);
}

static void
xpc_connection_remote_dead(void *context)
{

	xpc_connection_interrupt(context);
}

static void
xpc_connection_remote_proc_dead(void *context)
{

	xpc_connection_interrupt(context);
}

static void
xpc_connection_arm_proc_source(struct xpc_connection *conn)
{

	if (conn->xc_cancelled || conn->xc_sources_cancelled ||
	    conn->xc_proc_source != NULL || conn->xc_remote_pid <= 0 ||
	    conn->xc_remote_pid == getpid())
		return;

	conn->xc_proc_pid = conn->xc_remote_pid;
	conn->xc_proc_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,
	    conn->xc_proc_pid, DISPATCH_PROC_EXIT, conn->xc_recv_queue);
	if (conn->xc_proc_source == NULL)
		return;

	dispatch_set_context(conn->xc_proc_source, conn);
	dispatch_source_set_event_handler_f(conn->xc_proc_source,
	    xpc_connection_remote_proc_dead);
	dispatch_resume(conn->xc_proc_source);
}

static void
xpc_connection_set_credentials(struct xpc_connection *conn, audit_token_t *tok)
{
	uid_t uid;
	gid_t gid;
	pid_t pid;
	au_asid_t asid;

	if (tok == NULL)
		return;

	audit_token_to_au32(*tok, NULL, &uid, &gid, NULL, NULL, &pid, &asid,
	    NULL);

	conn->xc_remote_euid = uid;
	conn->xc_remote_guid = gid;
	conn->xc_remote_pid = pid;
	conn->xc_remote_asid = asid;
	xpc_connection_arm_proc_source(conn);
}

static void
xpc_connection_recv_message(void *context)
{
	struct xpc_pending_call *call;
	struct xpc_connection *conn, *peer;
	dispatch_queue_t queue;
	xpc_handler_t handler;
	xpc_object_t result;
	mach_port_t remote;
	kern_return_t kr;
	uint64_t id;

	debugf("connection=%p", context);

	conn = context;
	kr = xpc_pipe_receive(conn->xc_local_port, &remote, &result, &id);
	if (kr != KERN_SUCCESS)
		return;
	if (conn->xc_cancelled) {
		xpc_release(result);
		(void)mach_port_deallocate(mach_task_self(), remote);
		return;
	}

	debugf("message=%p, id=%d, remote=<%d>", result, id, remote);

	if (conn->xc_flags & XPC_CONNECTION_MACH_SERVICE_LISTENER) {
		TAILQ_FOREACH(peer, &conn->xc_peers, xc_link) {
			if (remote == peer->xc_remote_port) {
				if (!peer->xc_cancelled && peer->xc_handler != NULL)
					xpc_connection_dispatch_event(peer, result, remote);
				else
					(void)mach_port_deallocate(mach_task_self(), remote);
				xpc_release(result);
				return;
			}
		}

		debugf("new peer on port <%u>", remote);

		/* New peer */
		peer = xpc_connection_create(NULL, NULL);
		if (peer == NULL) {
			xpc_release(result);
			(void)mach_port_deallocate(mach_task_self(), remote);
			return;
		}
		peer->xc_parent = conn;
		peer->xc_remote_port = remote;
		peer->xc_owns_remote_port = true;
		xpc_connection_set_credentials(peer,
		    ((struct xpc_object *)result)->xo_audit_token);

		TAILQ_INSERT_TAIL(&conn->xc_peers, peer, xc_link);

		/* The listener's serial receive queue targets its requested queue. */
		handler = conn->xc_handler != NULL ?
		    (xpc_handler_t)Block_copy(conn->xc_handler) : NULL;
		if (handler != NULL) {
			handler(peer);
			Block_release(handler);
		}

		/* Peer setup has completed; its receive queue now holds delivery. */
		if (!peer->xc_cancelled && peer->xc_handler != NULL)
			xpc_connection_dispatch_event(peer, result, MACH_PORT_NULL);
		xpc_release(result);

	} else {
		xpc_connection_set_credentials(conn,
		    ((struct xpc_object *)result)->xo_audit_token);

		TAILQ_FOREACH(call, &conn->xc_pending, xp_link) {
			if (call->xp_id == id) {
				TAILQ_REMOVE(&conn->xc_pending, call, xp_link);
				call->xp_response = result;
				call->xp_remote_port = remote;
				queue = call->xp_queue ? call->xp_queue :
				    conn->xc_target_queue;
				dispatch_async_f(queue, call,
				    xpc_connection_invoke_pending);
				return;
			}
		}

		if (conn->xc_handler != NULL)
			xpc_connection_dispatch_event(conn, result, remote);
		else
			(void)mach_port_deallocate(mach_task_self(), remote);
		xpc_release(result);
	}
}
