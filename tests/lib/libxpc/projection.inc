/* Private field projection only. */
unsigned op500_local(struct xpc_connection *c) { return c->xc_local_port; }
int op736_audit_pid(struct xpc_object *o) { return o->xo_audit_token ? o->xo_audit_token->val[5] : -1; }
int op736_pipe_receive(unsigned p, unsigned *r, xpc_object_t *o, uint64_t *id) { return xpc_pipe_receive(p, r, o, id); }
void op500_remote(struct xpc_connection *c,unsigned p) { c->xc_remote_port=p; c->xc_owns_remote_port=true; }
unsigned op500_cancel_count(struct xpc_connection *c) { return c->xc_source_cancel_count; }
unsigned op500_cancelled(struct xpc_connection *c) { return c->xc_cancelled; }
void *op500_send_queue(struct xpc_connection *c) { return c->xc_send_queue; }
void *op500_recv_queue(struct xpc_connection *c) { return c->xc_recv_queue; }
int op500_pipe_send(xpc_object_t o,unsigned dst,unsigned local,uint64_t id) { return xpc_pipe_send(o,dst,local,id); }
unsigned op502_interrupted(struct xpc_connection *c) { return c->xc_interrupted; }
void op502_peer(struct xpc_connection *c) { c->xc_parent=c; }
int op507_proc_pid(struct xpc_connection *c) { int p; pthread_mutex_lock(&c->xc_remote_lock); p=c->xc_proc_pid; pthread_mutex_unlock(&c->xc_remote_lock); return p; }
int op507_remote_pid(struct xpc_connection *c) { int p; pthread_mutex_lock(&c->xc_remote_lock); p=c->xc_remote_pid; pthread_mutex_unlock(&c->xc_remote_lock); return p; }
