/*-
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef _THR_WORKQ_IDLE_H_
#define _THR_WORKQ_IDLE_H_

#include <stdint.h>

/* XNU workq_kill_delay_for_idle_thread: milliseconds, ordinary idle pool. */
static inline uint64_t
twq_idle_delay_msec(uint32_t idle, uint32_t cpus)
{
	uint32_t cap, threshold, n;
	uint64_t delay;

	threshold = 1;
	for (n = cpus; n != 0; n >>= 1)
		threshold++;
	cap = cpus > 12 ? cpus * 5 : 64;
	if (cap > 512)
		cap = 512;
	delay = 5000;
	if (idle <= threshold)
		return (delay);
	if (idle - threshold < cap)
		delay *= cap - (idle - threshold);
	return (delay / cap);
}

#endif /* !_THR_WORKQ_IDLE_H_ */
