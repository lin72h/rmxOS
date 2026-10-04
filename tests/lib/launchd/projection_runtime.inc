/* Test-only C ABI projection for the real PID-1 demand callback. */
void op484_demand_scan(void) { mportset_callback(); }
unsigned op484_demand_set(void) { return demand_port_set; }
