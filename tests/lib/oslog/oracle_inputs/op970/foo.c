#include "shared.h"
const char *foo_literal(void) { return "foo-literal"; }
void foo_log(os_log_t log, const char *string) {
    os_log(log, TAG " A02 value=[%s]", string);
}
