/*
 * launchd is built against the Darwin uuid_compare(uuid_t, uuid_t) ABI.
 * FreeBSD libc exposes a different uuid_compare signature, so keep the
 * Darwin-shaped symbol in the compatibility archive.
 */

#include <string.h>
#include <uuid/uuid.h>

int
uuid_compare(const uuid_t uu1, const uuid_t uu2)
{
	return (memcmp(uu1, uu2, sizeof(uuid_t)));
}
