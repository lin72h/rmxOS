/* SPDX-License-Identifier: BSD-2-Clause */
/* Internal codec contract. This header is not installed. */
#ifndef _LIBC_OSLOG_CODEC_H_
#define _LIBC_OSLOG_CODEC_H_
#include <sys/cdefs.h>

#include <stddef.h>
#include <stdint.h>
#define __OSLOG_CODEC_CAP 1024
/* One macOS 27 direct-main fault observation: 1989 string bytes + 9 overhead.
 */
#define __OSLOG_CODEC_FAULT_CAP 1998
#define __OSLOG_CODEC_STORAGE	2048
/* Readers copy up to the requested number of bytes and return the number
 * copied, or EFAULT for inaccessible input. A successful copy makes progress.
 * The codec never dereferences captured pointer values. */
typedef int (*__oslog_range_reader)(void *, uintptr_t, size_t, unsigned char *,
    size_t, size_t *);
__hidden int __oslog_codec_literal(const void *);
__hidden int __oslog_codec_flatten(const char *, size_t, const unsigned char *,
    size_t, unsigned, __oslog_range_reader, void *, unsigned char *, size_t,
    size_t *);
__hidden int __oslog_codec_render(const char *, size_t, const unsigned char *,
    size_t, char *, size_t, size_t *);
#endif
