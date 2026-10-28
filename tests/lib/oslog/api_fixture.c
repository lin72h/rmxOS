/* Compiler input only. Assertions and transport substitution are in Zig. */
#include <os/log.h>
#include <os/trace.h>
void api_emit(os_log_t, os_log_type_t, const char *, const char *);
void api_five(os_log_t);
void api_wide(os_log_t);
void api_once(os_log_t, int *);
void
api_emit(os_log_t log, os_log_type_t type, const char *private_value,
    const char *public_value)
{
	os_log_with_type(log, type,
	    "canary private=[%{private}s] public=[%{public}s]", private_value,
	    public_value);
}
void
api_five(os_log_t log)
{
	os_log(log, "default");
	os_log_info(log, "info");
	os_log_debug(log, "debug");
	os_log_error(log, "error");
	os_log_fault(log, "fault");
}
void
api_wide(os_log_t log)
{
	os_log(log, "%S", L"not supported");
}
void
api_once(os_log_t log, int *value)
{

	os_log(log, "once=%d", (*value)++);
}
