/* Test-only C ABI projection. Scheduling and observations belong to Zig. */
unsigned op495_job_port(job_t j) { return j->j_port; }
int op495_port_for_label(job_t j, char *label, mach_port_t *p) {
    struct ldcred *cred = runtime_get_caller_creds();
    struct ldcred saved = *cred;
    cred->euid = 0;
    int result = job_mig_port_for_label(j, label, p);
    *cred = saved;
    return result;
}
void *op484_first_service(job_t j) { return SLIST_FIRST(&j->machservices); }
unsigned op484_service_port(struct machservice *ms) { return ms->port; }
int op484_job_pid(job_t j) { return j->p; }
unsigned op484_job_runs(job_t j) { return j->nruns; }
int op484_job_status(job_t j) { return j->last_exit_status; }
void op484_watch(job_t j, struct machservice *ms) { machservice_watch(j, ms); }
void *op484_send_service(job_t j, const char *name, mach_port_t *p) {
    return machservice_new(j, name, p, false);
}
unsigned op484_request_size(void) {
    return 2 * sizeof(union __RequestUnion__catch_mach_exc_subsystem);
}
unsigned op484_reply_size(void) {
    return sizeof(union __ReplyUnion__catch_mach_exc_subsystem);
}
