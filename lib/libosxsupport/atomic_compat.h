/*
 * Copyright 2014-2015 iXsystems, Inc.
 * All rights reserved
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted providing that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

#ifndef RMX_ATOMIC_COMPAT_H
#define RMX_ATOMIC_COMPAT_H
#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

typedef int32_t OSSpinLock;

static inline int32_t
rmx_osatomic_inc32(volatile int32_t *value, int order)
{
	return __atomic_add_fetch(value, 1, order);
}
static inline int32_t
rmx_osatomic_dec32(volatile int32_t *value, int order)
{
	return __atomic_sub_fetch(value, 1, order);
}
static inline int64_t
rmx_osatomic_add64(int64_t amount, volatile int64_t *value)
{
	return __atomic_add_fetch(value, amount, __ATOMIC_RELAXED);
}
static inline bool
rmx_osatomic_test_and_set(uint32_t bit, volatile void *address)
{
	volatile uint8_t *byte = (volatile uint8_t *)address + (bit >> 3);
	uint8_t mask = (uint8_t)(0x80u >> (bit & 7));
	return (__atomic_fetch_or(byte, mask, __ATOMIC_SEQ_CST) & mask) != 0;
}
static inline bool
rmx_osatomic_cas32(int32_t old, int32_t replacement, volatile int32_t *value)
{
	return __atomic_compare_exchange_n(value, &old, replacement, false,
	    __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
static inline bool
rmx_osatomic_caslong(long old, long replacement, volatile long *value)
{
	return __atomic_compare_exchange_n(value, &old, replacement, false,
	    __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
static inline void
rmx_osspin_lock(volatile OSSpinLock *lock)
{
	while (__atomic_exchange_n(lock, 1, __ATOMIC_ACQUIRE) != 0)
		while (__atomic_load_n(lock, __ATOMIC_RELAXED) != 0)
			__asm__ volatile("pause");
}
static inline void
rmx_osspin_unlock(volatile OSSpinLock *lock)
{
	__atomic_store_n(lock, 0, __ATOMIC_RELEASE);
}
#define OSAtomicIncrement32Barrier(v) rmx_osatomic_inc32((v), __ATOMIC_SEQ_CST)
#define OSAtomicDecrement32Barrier(v) rmx_osatomic_dec32((v), __ATOMIC_SEQ_CST)
#define OSAtomicTestAndSetBarrier(i, v) rmx_osatomic_test_and_set((i), (v))
#define OSAtomicAdd64(i, v) rmx_osatomic_add64((i), (v))
#define OSAtomicIncrement32(v) rmx_osatomic_inc32((v), __ATOMIC_RELAXED)
#define OSAtomicDecrement32(v) rmx_osatomic_dec32((v), __ATOMIC_RELAXED)
#define OSAtomicCompareAndSwapLongBarrier(o, i, v) rmx_osatomic_caslong((o), (i), (v))
#define OSAtomicCompareAndSwap32Barrier(o, i, v) rmx_osatomic_cas32((o), (i), (v))
#define OSSpinLockLock(l) rmx_osspin_lock(l)
#define OSSpinLockUnlock(l) rmx_osspin_unlock(l)
#endif
