/* C ABI projections only. Zig controls the test and records observations. */
#include <mach/mach.h>
#include <stdlib.h>

int op495_notify(unsigned, unsigned);
kern_return_t __real_launchd_mport_notify_req(mach_port_t, mach_msg_id_t);
kern_return_t __wrap_launchd_mport_notify_req(mach_port_t, mach_msg_id_t);
kern_return_t __wrap_launchd_mport_notify_req(mach_port_t p, mach_msg_id_t id) {
    int injected = op495_notify(p, id);
    return injected ? injected : __real_launchd_mport_notify_req(p, id);
}

void op484_init(void);
void op484_allocation(void *, size_t, size_t);
void op484_free(void *);
unsigned op484_before_receive(unsigned, unsigned, unsigned);
void op484_after_receive(mach_msg_header_t *, unsigned, unsigned, int);
void op484_attributes(unsigned, int, unsigned);
void op484_move(unsigned, unsigned, int);
void op484_close(unsigned, unsigned, int);
void op484_members(mach_port_name_t *, unsigned);
void op484_lookup(unsigned, void *);
struct job_s *__wrap_job_find_by_service_port(mach_port_t);
kern_return_t __wrap_mach_port_get_set_status(mach_port_t, mach_port_name_t,
    mach_port_name_array_t *, mach_msg_type_number_t *);
void __wrap_launchd_runtime_init2(void);
void *__wrap_calloc(size_t, size_t);
void __wrap_free(void *);
mach_msg_return_t __wrap_mach_msg(mach_msg_header_t *, mach_msg_option_t,
    mach_msg_size_t, mach_msg_size_t, mach_port_name_t, mach_msg_timeout_t,
    mach_port_name_t);
kern_return_t __wrap_mach_port_get_attributes(mach_port_t, mach_port_name_t,
    mach_port_flavor_t, mach_port_info_t, mach_msg_type_number_t *);
kern_return_t __wrap_mach_port_move_member(mach_port_t, mach_port_name_t, mach_port_name_t);
kern_return_t __wrap_mach_port_mod_refs(mach_port_t, mach_port_name_t,
    mach_port_right_t, mach_port_delta_t);

void __real_launchd_runtime_init2(void);
void __wrap_launchd_runtime_init2(void) {
    __real_launchd_runtime_init2();
    op484_init();
}
void *__real_calloc(size_t, size_t);
void *__wrap_calloc(size_t n, size_t size) {
    void *p = __real_calloc(n, size);
    op484_allocation(p, n, size);
    return p;
}
void __real_free(void *);
void __wrap_free(void *p) {
    op484_free(p);
    __real_free(p);
}
mach_msg_return_t __real_mach_msg(mach_msg_header_t *, mach_msg_option_t,
    mach_msg_size_t, mach_msg_size_t, mach_port_name_t, mach_msg_timeout_t,
    mach_port_name_t);
mach_msg_return_t __wrap_mach_msg(mach_msg_header_t *h, mach_msg_option_t opts,
    mach_msg_size_t send_size, mach_msg_size_t recv_size, mach_port_name_t name,
    mach_msg_timeout_t timeout, mach_port_name_t notify) {
    unsigned stop = op484_before_receive(opts, name, recv_size);
    mach_msg_return_t r = stop ? stop : __real_mach_msg(h, opts, send_size,
        recv_size, name, timeout, notify);
    op484_after_receive(h, opts, name, r);
    return r;
}
kern_return_t __real_mach_port_get_attributes(mach_port_t, mach_port_name_t,
    mach_port_flavor_t, mach_port_info_t, mach_msg_type_number_t *);
kern_return_t __wrap_mach_port_get_attributes(mach_port_t task,
    mach_port_name_t p, mach_port_flavor_t flavor, mach_port_info_t info,
    mach_msg_type_number_t *count) {
    kern_return_t r = __real_mach_port_get_attributes(task, p, flavor, info, count);
    op484_attributes(p, r, flavor == MACH_PORT_RECEIVE_STATUS && r == KERN_SUCCESS
        ? ((mach_port_status_t *)info)->mps_msgcount : 0);
    return r;
}
kern_return_t __real_mach_port_move_member(mach_port_t, mach_port_name_t, mach_port_name_t);
kern_return_t __wrap_mach_port_move_member(mach_port_t task, mach_port_name_t p,
    mach_port_name_t set) {
    kern_return_t r = __real_mach_port_move_member(task, p, set);
    op484_move(p, set, r);
    return r;
}
kern_return_t __real_mach_port_mod_refs(mach_port_t, mach_port_name_t,
    mach_port_right_t, mach_port_delta_t);
kern_return_t __wrap_mach_port_mod_refs(mach_port_t task, mach_port_name_t p,
    mach_port_right_t right, mach_port_delta_t delta) {
    op484_close(p, right, delta);
    return __real_mach_port_mod_refs(task, p, right, delta);
}
struct job_s *__real_job_find_by_service_port(mach_port_t);
struct job_s *__wrap_job_find_by_service_port(mach_port_t p) {
    struct job_s *j = __real_job_find_by_service_port(p);
    op484_lookup(p, j);
    return j;
}
kern_return_t __real_mach_port_get_set_status(mach_port_t, mach_port_name_t,
    mach_port_name_array_t *, mach_msg_type_number_t *);
kern_return_t __wrap_mach_port_get_set_status(mach_port_t task, mach_port_name_t p,
    mach_port_name_array_t *members, mach_msg_type_number_t *count) {
    kern_return_t r = __real_mach_port_get_set_status(task, p, members, count);
    if (r == KERN_SUCCESS) op484_members(*members, *count);
    return r;
}
