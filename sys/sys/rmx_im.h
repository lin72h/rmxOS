/* SPDX-License-Identifier: BSD-2-Clause */
#ifndef _SYS_RMX_IM_H_
#define _SYS_RMX_IM_H_

#include <stdbool.h>

#ifndef RMX_INSTRUMENT
#define RMPROBE(condition, comment) ((void)0)
#define RMBUGGIFY(comment) false
#else

#include <stdint.h>

/* ELF registration retains even sites in functions removed by section GC.
 * Counters are relaxed atomics; identity fields and strings are immutable.
 * A site's identity is (file, line, ordinal, kind); comment is its switch name.
 */
struct rmx_im_site {
	const char *file;
	const char *comment;
	unsigned line;
	unsigned ordinal;
	char kind;
	uint64_t hits;
	uint64_t checks;
};
extern struct rmx_im_site __start_rmx_im_sites[], __stop_rmx_im_sites[];

#ifdef _KERNEL
/* The kernel supplies its own switch provider; no libc dependency here. */
bool rmx_im_fault_selected(const struct rmx_im_site *);
#else
#include <stdlib.h>
#include <string.h>

/* Set RMX_IM_FAULTS to comma-separated, exact comment names before running.
 * Unset or unmatched names leave faults off. No RNG or scheduling dependency.
 * Tests may change the list between cases while their logger is quiescent.
 */
static inline bool
rmx_im_fault_selected(const struct rmx_im_site *site)
{
	const char *p = getenv("RMX_IM_FAULTS");
	if (p == NULL) return false;
	size_t length = strlen(site->comment);
	while (*p) {
		const char *end = strchr(p, ',');
		size_t n = end ? (size_t)(end - p) : strlen(p);
		if (n == length && memcmp(p, site->comment, n) == 0) return true;
		if (end == NULL) break;
		p = end + 1;
	}
	return false;
}
#endif

static inline bool
rmx_im_record(struct rmx_im_site *site, bool hit)
{
	__atomic_fetch_add(&site->checks, 1, __ATOMIC_RELAXED);
	if (hit) __atomic_fetch_add(&site->hits, 1, __ATOMIC_RELAXED);
	return hit;
}

#define _RMX_IM_SITE(type, text) \
	static struct rmx_im_site _rmx_site \
	    __attribute__((used, retain, section("rmx_im_sites"), aligned(8))) = \
	    { .file = __FILE__, .line = __LINE__, .ordinal = __COUNTER__, \
	      .comment = (text), .kind = (type) }
#define RMPROBE(condition, comment) do { \
	_RMX_IM_SITE('P', comment); \
	(void)rmx_im_record(&_rmx_site, !!(condition)); \
} while (0)
#define RMBUGGIFY(comment) __extension__ ({ \
	_RMX_IM_SITE('F', comment); \
	rmx_im_record(&_rmx_site, rmx_im_fault_selected(&_rmx_site)); \
})
#endif /* RMX_INSTRUMENT */
#endif /* _SYS_RMX_IM_H_ */
