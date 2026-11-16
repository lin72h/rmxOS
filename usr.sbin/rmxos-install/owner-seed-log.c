/* os_log's compiler-encoded format buffer stays in C. */
#include <os/log.h>
void rmxos_owner_log(const char *);
void
rmxos_owner_log(const char *message)
{
	os_log_t log = os_log_create("org.rmxos.owner-seed", "boot");
	os_log(log, "%{public}s", message);
}
