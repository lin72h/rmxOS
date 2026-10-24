/* Minimal ASL wire client, using only libc and libsys. No sender quota. */
#include <sys/types.h>
#include <sys/mach/message.h>
#include <sys/mach/ndr.h>
#include <sys/mach/task_special_ports.h>
#include <sys/syslog.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <inttypes.h>
#include "asl_private.h"

/* Use libsys's exported syscall entry points. The public Mach names are
 * not in libc's symbol map: its dynamic syscall objects contain empty stubs,
 * so those names bind locally instead of passing through the libsys filter. */
extern mach_port_t __sys_task_self_trap(void);
extern mach_port_t __sys_mach_reply_port(void);
extern int __sys__kernelrpc_mach_port_deallocate_trap(mach_port_t, mach_port_t);
extern int __sys__kernelrpc_mach_port_destroy_trap(mach_port_t, mach_port_t);
extern mach_msg_return_t __sys_mach_msg_trap(mach_msg_header_t *, mach_msg_option_t,
    mach_msg_size_t, mach_msg_size_t, mach_port_t, mach_msg_timeout_t, mach_port_t);

/* Match the ASL client: discovery and sends wait without a timeout. */
__attribute__((visibility("hidden"))) int __libc_asl_open(void);
__attribute__((visibility("hidden"))) void __libc_asl_close(void);

static pid_t owner;
static mach_port_t server, reply, bootstrap, task;
static const NDR_record_t ndr = { 0, 0, 0, 0, 1, 0, 0, 0 };

#pragma pack(push, 4)
struct port_reply {
	mach_msg_header_t head;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t port;
	unsigned char trailer[256];
};
struct lookup_request {
	mach_msg_header_t head;
	NDR_record_t ndr;
	char name[128];
	int target;
	unsigned char instance[16];
	uint64_t flags;
};
struct log_request {
	mach_msg_header_t head;
	mach_msg_body_t body;
	mach_msg_ool_descriptor_t bytes;
	NDR_record_t ndr;
	mach_msg_type_number_t count;
};
#pragma pack(pop)

static void
release_port(mach_port_t *port)
{
	if (*port != MACH_PORT_NULL)
		(void)__sys__kernelrpc_mach_port_deallocate_trap(task, *port);
	*port = MACH_PORT_NULL;
}

static int
port_rpc(mach_msg_header_t *request, size_t size, mach_port_t destination,
    int id, mach_port_t *result)
{
	struct port_reply response = {0};
	mach_msg_return_t kr;

	request->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
	    MACH_MSG_TYPE_MAKE_SEND_ONCE);
	request->msgh_remote_port = destination;
	request->msgh_size = size;
	request->msgh_local_port = reply;
	request->msgh_id = id;
	kr = __sys_mach_msg_trap(request, MACH_SEND_MSG,
	    size, 0, 0, 0, 0);
	if (kr != MACH_MSG_SUCCESS)
		return (-1);
	kr = __sys_mach_msg_trap(&response.head, MACH_RCV_MSG,
	    0, sizeof(response), reply, 0, 0);
	if (kr != MACH_MSG_SUCCESS) {
		/* A late reply must not satisfy a future lookup. */
		(void)__sys__kernelrpc_mach_port_destroy_trap(task, reply);
		reply = MACH_PORT_NULL;
		return (-1);
	}
	if (kr != MACH_MSG_SUCCESS || response.head.msgh_id != id + 100 ||
	    !(response.head.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
	    response.head.msgh_size != sizeof(mach_msg_header_t) +
	    sizeof(mach_msg_body_t) + sizeof(mach_msg_port_descriptor_t) ||
	    response.body.msgh_descriptor_count != 1 ||
	    response.port.type != MACH_MSG_PORT_DESCRIPTOR ||
	    response.port.disposition != MACH_MSG_TYPE_PORT_SEND)
		return (-1);
	*result = response.port.name;
	return (*result == MACH_PORT_NULL ? -1 : 0);
}

static int
lookup(void)
{
	struct {
		mach_msg_header_t head;
		NDR_record_t ndr;
		int which;
	} special = { .ndr = ndr, .which = TASK_BOOTSTRAP_PORT };
	struct lookup_request request = { .ndr = ndr };

	if (reply == MACH_PORT_NULL)
		reply = __sys_mach_reply_port();
	if (reply == MACH_PORT_NULL)
		return (-1);
	if (bootstrap == MACH_PORT_NULL && port_rpc(&special.head,
	    sizeof(special), task, 3409, &bootstrap) != 0)
		return (-1);
	strlcpy(request.name, "com.apple.system.logger", sizeof(request.name));
	return (port_rpc(&request.head, sizeof(request), bootstrap, 404, &server));
}

static void
reset_owner(void)
{
	pid_t pid = getpid();

	if (owner != pid) {
		task = __sys_task_self_trap();
		release_port(&server);
		release_port(&bootstrap);
		/* Drop only this child's descriptor reference. Destroying the
		 * inherited receive right would also invalidate the parent's RPC. */
		if (reply != MACH_PORT_NULL)
			(void)close(reply);
		reply = MACH_PORT_NULL;
		owner = pid;
	}
}

int
__libc_asl_open(void)
{

	reset_owner();
	return (server != MACH_PORT_NULL ? 0 : lookup());
}

void
__libc_asl_close(void)
{

	reset_owner();
	release_port(&server);
}

int
__libc_asl_send(const char *record)
{
	struct log_request request;
	mach_msg_return_t kr;
	size_t length = strlen(record) + 1;

	reset_owner();
	for (int attempt = 0; attempt < 2; attempt++) {
		if (server == MACH_PORT_NULL && lookup() != 0)
			return (-1);
		memset(&request, 0, sizeof(request));
		request.head.msgh_bits = MACH_MSGH_BITS_COMPLEX |
		    MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
		request.head.msgh_remote_port = server;
		request.head.msgh_id = 118;
		request.head.msgh_size = sizeof(request);
		request.body.msgh_descriptor_count = 1;
		request.bytes.address = (void *)(uintptr_t)record;
		request.bytes.size = length;
		/* The caller owns the buffer, including after a failed send. */
		request.bytes.deallocate = 0;
		request.bytes.copy = MACH_MSG_VIRTUAL_COPY;
		request.bytes.type = MACH_MSG_OOL_DESCRIPTOR;
		request.ndr = ndr;
		request.count = length;
		kr = __sys_mach_msg_trap(&request.head,
		    MACH_SEND_MSG, sizeof(request), 0, 0, 0, 0);
		if (kr == MACH_MSG_SUCCESS)
			return (0);
		release_port(&server);
	}
	return (-1);
}

static void
field(FILE *fp, const char *key, const char *value)
{
	fprintf(fp, "[%s ", key);
	for (const unsigned char *p = (const void *)value; *p; p++) {
		if (*p == '\\' || *p == '[' || *p == ']')
			fputc('\\', fp);
		if (*p == '\n') fputs("\\n", fp);
		else if (*p == '\r') fputs("\\r", fp);
		else fputc(*p, fp);
	}
	fputs("] ", fp);
}

char *
__libc_asl_record(const char *sender, int pid, int priority,
    const struct timeval *time, const char *host, const char *message,
    uint64_t dropped)
{
	static const char *facilities[] = { "kern", "user", "mail", "daemon",
	    "auth", "syslog", "lpr", "news", "uucp", "cron", "authpriv",
	    "ftp", "ntp", "security", "console", "launchd", "local0",
	    "local1", "local2", "local3", "local4", "local5", "local6", "local7" };
	char *record = NULL;
	size_t length = 0;
	FILE *fp = open_memstream(&record, &length);
	unsigned facility = LOG_FAC(priority);
	if (fp == NULL) return (NULL);
	field(fp, "Sender", sender);
	fprintf(fp, "[Level %d] [Facility %s] [PID %d] [Time %jd] "
	    "[TimeNanoSec %ld] ", LOG_PRI(priority),
	    facility < sizeof(facilities) / sizeof(*facilities) ? facilities[facility] : "user",
	    pid, (intmax_t)time->tv_sec, time->tv_usec * 1000);
	field(fp, "Host", host);
	field(fp, "Message", message);
	if (dropped != 0)
		fprintf(fp, "[com.rmxos.syslog.sender_dropped %" PRIu64 "]", dropped);
	if (fclose(fp) != 0) { free(record); return (NULL); }
	return (record);
}
