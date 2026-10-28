/*
 * Copyright (c) 2015-2023 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

/* rmxOS user-space adaptation of the XNU public API. */
#ifndef __os_log_h
#define __os_log_h
#include <os/object.h>
#include <stdbool.h>
#include <stdint.h>

__BEGIN_DECLS
typedef struct os_log_s *os_log_t;
typedef uint8_t os_log_type_t;
enum {
	OS_LOG_TYPE_DEFAULT = 0x00,
	OS_LOG_TYPE_INFO = 0x01,
	OS_LOG_TYPE_DEBUG = 0x02,
	OS_LOG_TYPE_ERROR = 0x10,
	OS_LOG_TYPE_FAULT = 0x11
};
OS_EXPORT struct os_log_s _os_log_default;
OS_EXPORT struct os_log_s _os_log_disabled;
#define OS_LOG_DEFAULT	       ((os_log_t) & _os_log_default)
#define OS_LOG_DISABLED	       ((os_log_t) & _os_log_disabled)
#define OS_LOG_BUFFER_MAX_SIZE 1024
#define OS_LOG_DATA_MAX_SIZE   (OS_LOG_BUFFER_MAX_SIZE - 16)
#define OS_LOG_STRING_SECTION  ".os_log"

OS_EXPORT os_log_t os_log_create(const char *, const char *);
OS_EXPORT bool os_log_type_enabled(os_log_t, os_log_type_t);
OS_EXPORT bool os_log_info_enabled(os_log_t);
OS_EXPORT bool os_log_debug_enabled(os_log_t);
OS_EXPORT __attribute__((not_tail_called)) void _os_log_impl(const void *,
    os_log_t, os_log_type_t, const char *, const uint8_t *, uint32_t);
OS_EXPORT __attribute__((not_tail_called)) void _os_log_debug_impl(const void *,
    os_log_t, os_log_type_t, const char *, const uint8_t *, uint32_t);
OS_EXPORT __attribute__((not_tail_called)) void _os_log_error_impl(const void *,
    os_log_t, os_log_type_t, const char *, const uint8_t *, uint32_t);
OS_EXPORT __attribute__((not_tail_called)) void _os_log_fault_impl(const void *,
    os_log_t, os_log_type_t, const char *, const uint8_t *, uint32_t);
__END_DECLS

/* An ELF-local opaque image token replaces the Mach-O dso header. Never
 * declare or dereference __dso_handle here: trace.h's declaration is compatible
 * with inclusion in either order. The implementation identifies the image by
 * the call PC, not by interpreting this token as a platform header. */
#ifdef __cplusplus
#define _OS_LOG_ASSERT static_assert
#else
#define _OS_LOG_ASSERT _Static_assert
#endif
#define _os_log_call(entry, log, type, format, ...)                         \
	__extension__({                                                     \
		_OS_LOG_ASSERT(__builtin_constant_p(format),                \
		    "format string must be constant");                      \
		static const char _os_log_fmt[]                             \
		    __attribute__((section(OS_LOG_STRING_SECTION),          \
			used)) = format;                                    \
		static const unsigned char _os_log_image = 0;               \
		os_log_t _os_log_object = (log);                            \
		os_log_type_t _os_log_type = (type);                        \
		if (os_log_type_enabled(_os_log_object, _os_log_type)) {    \
			uint8_t _os_log_buffer                              \
			    [__builtin_os_log_format_buffer_size(format,    \
				##__VA_ARGS__)];                            \
			__builtin_os_log_format(_os_log_buffer, format,     \
			    ##__VA_ARGS__);                                 \
			entry(&_os_log_image, _os_log_object, _os_log_type, \
			    _os_log_fmt, _os_log_buffer,                    \
			    sizeof(_os_log_buffer));                        \
		}                                                           \
		__asm__("");                                                \
	})
#define os_log_with_type(log, type, format, ...) \
	_os_log_call(_os_log_impl, log, type, format, ##__VA_ARGS__)
#define os_log(log, format, ...) \
	os_log_with_type(log, OS_LOG_TYPE_DEFAULT, format, ##__VA_ARGS__)
#define os_log_info(log, format, ...) \
	os_log_with_type(log, OS_LOG_TYPE_INFO, format, ##__VA_ARGS__)
#define os_log_debug(log, format, ...)                                   \
	_os_log_call(_os_log_debug_impl, log, OS_LOG_TYPE_DEBUG, format, \
	    ##__VA_ARGS__)
#define os_log_error(log, format, ...)                                   \
	_os_log_call(_os_log_error_impl, log, OS_LOG_TYPE_ERROR, format, \
	    ##__VA_ARGS__)
#define os_log_fault(log, format, ...)                                   \
	_os_log_call(_os_log_fault_impl, log, OS_LOG_TYPE_FAULT, format, \
	    ##__VA_ARGS__)
#endif
