/*
 * Copyright (c) 2008-2013 Apple Inc. All rights reserved.
 *
 * @APPLE_APACHE_LICENSE_HEADER_START@
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * @APPLE_APACHE_LICENSE_HEADER_END@
 */

#include "internal.h"

uint64_t
_dispatch_get_nanoseconds(void)
{
#if !TARGET_OS_WIN32
	struct timeval now;
	int r = gettimeofday(&now, NULL);
	dispatch_assert_zero(r);
	dispatch_assert(sizeof(NSEC_PER_SEC) == 8);
	dispatch_assert(sizeof(NSEC_PER_USEC) == 8);
	return (uint64_t)now.tv_sec * NSEC_PER_SEC +
			(uint64_t)now.tv_usec * NSEC_PER_USEC;
#else /* TARGET_OS_WIN32 */
	// FILETIME is 100-nanosecond intervals since January 1, 1601 (UTC).
	FILETIME ft;
	ULARGE_INTEGER li;
	GetSystemTimeAsFileTime(&ft);
	li.LowPart = ft.dwLowDateTime;
	li.HighPart = ft.dwHighDateTime;
	return li.QuadPart * 100ull;
#endif /* TARGET_OS_WIN32 */
}

#if !(defined(__i386__) || defined(__x86_64__) || !HAVE_MACH_ABSOLUTE_TIME) \
		|| TARGET_OS_WIN32
DISPATCH_CACHELINE_ALIGN _dispatch_host_time_data_s _dispatch_host_time_data = {
	.ratio_1_to_1 = true,
};

void
_dispatch_get_host_time_init(void *context DISPATCH_UNUSED)
{
#if !TARGET_OS_WIN32
	mach_timebase_info_data_t tbi;
	(void)dispatch_assume_zero(mach_timebase_info(&tbi));
	_dispatch_host_time_data.frac = tbi.numer;
	_dispatch_host_time_data.frac /= tbi.denom;
	_dispatch_host_time_data.ratio_1_to_1 = (tbi.numer == tbi.denom);
#else
	LARGE_INTEGER freq;
	dispatch_assume(QueryPerformanceFrequency(&freq));
	_dispatch_host_time_data.frac = (long double)NSEC_PER_SEC /
			(long double)freq.QuadPart;
	_dispatch_host_time_data.ratio_1_to_1 = (freq.QuadPart == 1);
#endif	/* TARGET_OS_WIN32 */
}
#endif

dispatch_time_t
dispatch_time(dispatch_time_t inval, int64_t delta)
{
	dispatch_clock_t clock;
	uint64_t value, offset;
	if (inval == DISPATCH_TIME_FOREVER) return DISPATCH_TIME_FOREVER;
	_dispatch_time_decode(inval, &clock, &value);
	if (value == DISPATCH_TIME_FOREVER) return value;
	if (!value && clock != DISPATCH_CLOCK_WALL) {
		value = clock == DISPATCH_CLOCK_UPTIME ? _dispatch_absolute_time() :
				_dispatch_monotonic_time();
	}
	/* Unsigned magnitude also handles INT64_MIN without signed overflow. */
	offset = delta < 0 ? -(uint64_t)delta : (uint64_t)delta;
	if (clock == DISPATCH_CLOCK_UPTIME) {
		offset = _dispatch_time_nano2mach(offset);
	}
	if (delta < 0) {
		value = offset >= value ? (clock == DISPATCH_CLOCK_WALL ? 2 : 1) :
				value - offset;
		if (clock == DISPATCH_CLOCK_WALL && value <= 1) value = 2;
	} else {
		if (offset >= DISPATCH_TIME_MAX_VALUE ||
				value >= DISPATCH_TIME_MAX_VALUE - offset) {
			return DISPATCH_TIME_FOREVER;
		}
		value += offset;
	}
	return _dispatch_time_encode(clock, value);
}

dispatch_time_t
dispatch_walltime(const struct timespec *inval, int64_t delta)
{
	uint64_t value, offset;
	value = inval ? (uint64_t)inval->tv_sec * NSEC_PER_SEC +
			(uint64_t)inval->tv_nsec : _dispatch_get_nanoseconds();
	offset = delta < 0 ? -(uint64_t)delta : (uint64_t)delta;
	if (delta < 0) {
		if (offset >= value || value - offset <= 1) return (dispatch_time_t)-2;
		value -= offset;
	} else {
		if (offset >= DISPATCH_TIME_MAX_VALUE ||
				value >= DISPATCH_TIME_MAX_VALUE - offset) {
			return DISPATCH_TIME_FOREVER;
		}
		value += offset;
	}
	if (value <= 1) return delta >= 0 ? DISPATCH_TIME_FOREVER : (dispatch_time_t)-2;
	return _dispatch_time_encode(DISPATCH_CLOCK_WALL, value);
}

uint64_t
_dispatch_timeout(dispatch_time_t when)
{
	dispatch_clock_t clock;
	uint64_t value, now;
	if (when == DISPATCH_TIME_FOREVER) return DISPATCH_TIME_FOREVER;
	if (when == DISPATCH_TIME_NOW) return 0;
	_dispatch_time_decode(when, &clock, &value);
	if (value == DISPATCH_TIME_FOREVER) return value;
	switch (clock) {
	case DISPATCH_CLOCK_WALL: now = _dispatch_get_nanoseconds(); break;
	case DISPATCH_CLOCK_MONOTONIC: now = _dispatch_monotonic_time(); break;
	case DISPATCH_CLOCK_UPTIME: now = _dispatch_absolute_time(); break;
	}
	if (now >= value) return 0;
	return clock == DISPATCH_CLOCK_UPTIME ?
			_dispatch_time_mach2nano(value - now) : value - now;
}
