/* ASL-private locking; the donor OSSpinLock bit/mask shim is not used here. */
#ifndef ASLD_LOCK_H
#define ASLD_LOCK_H
#include <pthread.h>
typedef pthread_mutex_t asld_lock_t;
#define ASLD_LOCK_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#define asld_lock_init(l) pthread_mutex_init((l), NULL)
#define asld_lock_lock(l) pthread_mutex_lock(l)
#define asld_lock_unlock(l) pthread_mutex_unlock(l)
#endif
