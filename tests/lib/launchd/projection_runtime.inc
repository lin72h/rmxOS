/* Test-only C ABI projection for the real PID-1 demand callback. */
void op484_demand_scan(void) { mportset_callback(); }
unsigned op484_demand_set(void) { return demand_port_set; }

size_t op484_callback_slots(void) { return mig_cb_table_sz / sizeof(*mig_cb_table); }
