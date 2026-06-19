/*
 * Build-compat surface for launchd while the donor libinfo search/cache
 * modules remain gated in libosxsupport_rmx.
 */

#include <stdint.h>

extern uint32_t gL1CacheEnabled;
void si_search_module_set_flags(const char *name, uint32_t flag);

uint32_t gL1CacheEnabled = 1;

void
si_search_module_set_flags(const char *name __unused, uint32_t flag __unused)
{
}
