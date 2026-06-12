#ifndef NOTIFYD_N2_MARKERS_H
#define NOTIFYD_N2_MARKERS_H

#include <sys/types.h>
#include <stdint.h>
#include <launch.h>
#include <mach/mach.h>

void notifyd_n2_launchd_checkin_request(launch_data_t response);
void notifyd_n2_launchd_mach_services(launch_data_t mach_services);
void notifyd_n2_launchd_service_entry(const char *service, launch_data_t entry);
void notifyd_n2_launchd_receive_right(const char *service, mach_port_t port);
void notifyd_n2_launchd_terminal(int status);

void notifyd_n2_kernel_mach_msg_receive(mach_msg_header_t *head,
    uint32_t trailer_size);
void notifyd_n2_kernel_audit_trailer(audit_token_t audit);
void notifyd_n2_proc_source_create(pid_t pid);
void notifyd_n2_proc_source_event(pid_t pid);
void notifyd_n2_mach_send_source_create(mach_port_t notify_port,
    mach_port_t registered_name, int source_created);
void notifyd_n2_mach_send_dead_event(mach_port_t registered_name,
    unsigned long data);

#endif
