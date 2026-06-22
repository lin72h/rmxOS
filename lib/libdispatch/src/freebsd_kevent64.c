#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

#include "freebsd_compat.h"

#undef kevent64
#define DISPATCH_KEVENT64_STACK_MAX 8

static void
phase07_kevent64_to_kevent(const struct kevent64_s *src, struct kevent *dst)
{
	dst->ident = (uintptr_t)src->ident;
	dst->filter = src->filter;
	dst->flags = src->flags;
	dst->fflags = src->fflags;
	dst->data = src->data;
	dst->udata = (void *)(uintptr_t)src->udata;
	dst->ext[0] = src->ext[0];
	dst->ext[1] = src->ext[1];
	dst->ext[2] = 0;
	dst->ext[3] = 0;
}

static void
phase07_kevent_to_kevent64(const struct kevent *src, struct kevent64_s *dst)
{
	dst->ident = src->ident;
	dst->filter = src->filter;
	dst->flags = src->flags;
	dst->fflags = src->fflags;
	dst->data = src->data;
	dst->udata = (uint64_t)(uintptr_t)src->udata;
	dst->ext[0] = src->ext[0];
	dst->ext[1] = src->ext[1];
}

int
_dispatch_kevent64(int kq, const struct kevent64_s *changelist, int nchanges,
	struct kevent64_s *eventlist, int nevents, unsigned int flags,
	const struct timespec *timeout)
{
	struct kevent stack_changes[DISPATCH_KEVENT64_STACK_MAX];
	struct kevent stack_events[DISPATCH_KEVENT64_STACK_MAX];
	struct kevent *changes = NULL, *heap_changes = NULL;
	struct kevent *events = NULL, *heap_events = NULL;
	int ret;
	int i;

	if (flags != 0) {
		errno = ENOTSUP;
		return -1;
	}
	if (nchanges < 0 || nevents < 0) {
		errno = EINVAL;
		return -1;
	}
	if (nchanges > 0 && changelist == NULL) {
		errno = EINVAL;
		return -1;
	}
	if (nevents > 0 && eventlist == NULL) {
		errno = EINVAL;
		return -1;
	}

	if (nchanges > 0) {
		if (nchanges <= DISPATCH_KEVENT64_STACK_MAX) {
			changes = stack_changes;
		} else {
			heap_changes = calloc((size_t)nchanges, sizeof(*changes));
			changes = heap_changes;
		}
		if (changes == NULL) {
			return -1;
		}
		for (i = 0; i < nchanges; i++) {
			phase07_kevent64_to_kevent(&changelist[i], &changes[i]);
		}
	}

	if (nevents > 0) {
		if (nevents <= DISPATCH_KEVENT64_STACK_MAX) {
			events = stack_events;
		} else {
			heap_events = calloc((size_t)nevents, sizeof(*events));
			events = heap_events;
		}
		if (events == NULL) {
			free(heap_changes);
			return -1;
		}
	}

	ret = kevent(kq, changes, nchanges, events, nevents, timeout);
	if (ret > 0) {
		for (i = 0; i < ret; i++) {
			phase07_kevent_to_kevent64(&events[i], &eventlist[i]);
		}
	}

	free(heap_events);
	free(heap_changes);
	return ret;
}
