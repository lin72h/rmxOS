#include "atomic_compat.h"
int32_t op_inc(int32_t *p, int barrier) { return barrier ? OSAtomicIncrement32Barrier(p) : OSAtomicIncrement32(p); }
int32_t op_dec(int32_t *p, int barrier) { return barrier ? OSAtomicDecrement32Barrier(p) : OSAtomicDecrement32(p); }
int op_bit(unsigned n, void *p) { return OSAtomicTestAndSetBarrier(n, p); }
int op_cas32(int32_t a,int32_t b,int32_t *p) { return OSAtomicCompareAndSwap32Barrier(a,b,p); }
int op_caslong(long a,long b,long *p) { return OSAtomicCompareAndSwapLongBarrier(a,b,p); }
int64_t op_add(int64_t delta,int64_t *p) { return OSAtomicAdd64(delta,p); }
static OSSpinLock fixture_lock;
void op_lock(void) { OSSpinLockLock(&fixture_lock); }
void op_unlock(void) { OSSpinLockUnlock(&fixture_lock); }
