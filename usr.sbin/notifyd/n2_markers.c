#include <sys/types.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <bsm/libbsm.h>
#include <launch.h>
#include <mach/mach.h>

#include "n2_markers.h"

#ifndef DISPATCH_MACH_SEND_DEAD
#define DISPATCH_MACH_SEND_DEAD 0x1
#endif

static int n2_enabled = -1;
static int n2_last_msgid;
static mach_port_t n2_last_local_port;
static mach_msg_size_t n2_last_size;
static uint32_t n2_last_trailer_size;

static int
notifyd_n2_enabled(void)
{
	const char *value;

	if (n2_enabled != -1)
		return n2_enabled;

	value = getenv("NXPLATFORM_NOTIFYD_N2_MARKERS");
	n2_enabled = (value != NULL) && !strcmp(value, "1");
	return n2_enabled;
}

static const char *
launch_type_name(launch_data_t value)
{
	if (value == NULL)
		return "null";

	switch (launch_data_get_type(value))
	{
	case LAUNCH_DATA_DICTIONARY:
		return "dict";
	case LAUNCH_DATA_ARRAY:
		return "array";
	case LAUNCH_DATA_FD:
		return "fd";
	case LAUNCH_DATA_INTEGER:
		return "integer";
	case LAUNCH_DATA_REAL:
		return "real";
	case LAUNCH_DATA_BOOL:
		return "bool";
	case LAUNCH_DATA_STRING:
		return "string";
	case LAUNCH_DATA_OPAQUE:
		return "opaque";
	case LAUNCH_DATA_ERRNO:
		return "errno";
	case LAUNCH_DATA_MACHPORT:
		return "machport";
	default:
		return "unknown";
	}
}

void
notifyd_n2_launchd_checkin_request(launch_data_t response)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_LAUNCHD_CHECKIN_REQUEST kr=%d result=%s\n",
	    response != NULL ? 0 : 1, launch_type_name(response));
	fflush(stdout);
}

void
notifyd_n2_launchd_mach_services(launch_data_t mach_services)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_LAUNCHD_MACH_SERVICES_DICT present=%d type=%s\n",
	    mach_services != NULL ? 1 : 0, launch_type_name(mach_services));
	fflush(stdout);
}

void
notifyd_n2_launchd_service_entry(const char *service, launch_data_t entry)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_LAUNCHD_SERVICE_ENTRY service=%s present=%d type=%s\n",
	    service != NULL ? service : "null", entry != NULL ? 1 : 0,
	    launch_type_name(entry));
	fflush(stdout);
}

void
notifyd_n2_launchd_receive_right(const char *service, mach_port_t port)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_LAUNCHD_RECEIVE_RIGHT service=%s port=%u right=receive\n",
	    service != NULL ? service : "null", (unsigned int)port);
	fflush(stdout);
}

void
notifyd_n2_launchd_terminal(int status)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_LAUNCHD_CHECKIN_TERMINAL status=%d\n", status);
	fflush(stdout);
}

void
notifyd_n2_kernel_mach_msg_receive(mach_msg_header_t *head,
    uint32_t trailer_type, uint32_t trailer_size)
{
	if (head == NULL)
		return;

	n2_last_msgid = head->msgh_id;
	n2_last_local_port = head->msgh_local_port;
	n2_last_size = head->msgh_size;
	n2_last_trailer_size = trailer_size;

	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_KERNEL_MACH_MSG_RECEIVE msgid=%d local_port=%u size=%u trailer_type=%u\n",
	    head->msgh_id, (unsigned int)head->msgh_local_port,
	    (unsigned int)head->msgh_size, (unsigned int)trailer_type);
	fflush(stdout);
}

void
notifyd_n2_kernel_audit_trailer(audit_token_t audit)
{
	uid_t auid = (uid_t)-1;
	uid_t euid = (uid_t)-1;
	gid_t egid = (gid_t)-1;
	pid_t pid = (pid_t)-1;

	if (!notifyd_n2_enabled())
		return;

	audit_token_to_au32(audit, &auid, &euid, &egid, NULL, NULL, &pid, NULL,
	    NULL);
	printf("NOTIFYD_N2_KERNEL_AUDIT_TRAILER msgid=%d client_pid=%d auid=%u euid=%u egid=%u trailer_size=%u\n",
	    n2_last_msgid, (int)pid, (unsigned int)auid, (unsigned int)euid,
	    (unsigned int)egid, n2_last_trailer_size);
	fflush(stdout);
	(void)n2_last_local_port;
	(void)n2_last_size;
}

void
notifyd_n2_proc_source_create(pid_t pid, int source_created)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_PROC_SOURCE_CREATE pid=%d source_created=%d\n",
	    (int)pid, source_created != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2_proc_source_event(pid_t pid)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_PROC_SOURCE_EVENT pid=%d\n", (int)pid);
	fflush(stdout);
}

void
notifyd_n2_mach_send_source_create(mach_port_t notify_port,
    mach_port_t registered_name, int source_created)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2_MACH_SEND_SOURCE_CREATE notify_port=%u registered_name=%u source_created=%d\n",
	    (unsigned int)notify_port, (unsigned int)registered_name,
	    source_created != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2_mach_send_dead_event(mach_port_t registered_name,
    unsigned long data)
{
	if (!notifyd_n2_enabled())
		return;

	if ((data & DISPATCH_MACH_SEND_DEAD) == 0)
		return;

	printf("NOTIFYD_N2_MACH_SEND_DEAD_EVENT registered_name=%u data=%lu\n",
	    (unsigned int)registered_name, data);
	fflush(stdout);
}

void
notifyd_n2c2b_proc_source_create(pid_t pid, int source_created)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_PROC_SOURCE_CREATE pid=%d source_created=%d\n",
	    (int)pid, source_created != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2c2b_proc_source_resume(pid_t pid, int resumed)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_PROC_SOURCE_RESUME pid=%d resumed=%d\n",
	    (int)pid, resumed != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2c2b_proc_event_enter(pid_t pid)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_PROC_EVENT_ENTER pid=%d\n", (int)pid);
	fflush(stdout);
}

void
notifyd_n2c2b_mach_send_source_create(mach_port_t registered_name,
    int source_created)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_MACH_SEND_SOURCE_CREATE registered_name=%u source_created=%d\n",
	    (unsigned int)registered_name, source_created != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2c2b_mach_send_source_resume(mach_port_t registered_name,
    int resumed)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_MACH_SEND_SOURCE_RESUME registered_name=%u resumed=%d\n",
	    (unsigned int)registered_name, resumed != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2c2b_portproc_insert(mach_port_t registered_name, const char *state)
{
	if (!notifyd_n2_enabled())
		return;

	if (state == NULL)
		state = "unknown";
	printf("NOTIFYD_N2C2B_PORTPROC_INSERT registered_name=%u state=%s\n",
	    (unsigned int)registered_name, state);
	fflush(stdout);
}

void
notifyd_n2c2b_send_right_retain(mach_port_t registered_name,
    kern_return_t kr)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_SEND_RIGHT_RETAIN registered_name=%u kr=%d\n",
	    (unsigned int)registered_name, (int)kr);
	fflush(stdout);
}

void
notifyd_n2c2b_portproc_lookup(mach_port_t registered_name, const char *site,
    int found)
{
	if (!notifyd_n2_enabled())
		return;

	if (site == NULL)
		site = "unknown";
	printf("NOTIFYD_N2C2B_PORTPROC_LOOKUP registered_name=%u site=%s found=%d\n",
	    (unsigned int)registered_name, site, found != 0 ? 1 : 0);
	fflush(stdout);
}

void
notifyd_n2c2b_port_event_enter(mach_port_t registered_name,
    unsigned long data)
{
	if (!notifyd_n2_enabled())
		return;

	printf("NOTIFYD_N2C2B_PORT_EVENT_ENTER registered_name=%u data=%lu\n",
	    (unsigned int)registered_name, data);
	fflush(stdout);
}
