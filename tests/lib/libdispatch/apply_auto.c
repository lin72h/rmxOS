/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * DISPATCH_APPLY_AUTO as a C consumer of the public header sees it; Zig 0.16
 * cannot translate the _Nonnull cast in the macro. This builds only where
 * <dispatch/queue.h> defines it.
 */
#include <dispatch/dispatch.h>

dispatch_queue_t rmx_apply_auto(void);

dispatch_queue_t
rmx_apply_auto(void)
{
	return DISPATCH_APPLY_AUTO;
}
