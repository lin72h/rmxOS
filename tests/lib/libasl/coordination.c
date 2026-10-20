/* Test-only ABI projection: parser debug logging is not a system-log input. */
#include <stddef.h>
#include "asl_input.h"
int asldebug(const char *format, ...) { (void)format; return 0; }
size_t op752_klog_state_size(void) { return sizeof(struct asl_klog_state); }
