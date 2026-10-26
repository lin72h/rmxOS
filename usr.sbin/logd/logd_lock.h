/* ASL-private locking; the donor OSSpinLock bit/mask shim is not used here. */
#ifndef LOGD_LOCK_H
#define LOGD_LOCK_H
#include <pthread.h>
typedef pthread_mutex_t logd_lock_t;
#define LOGD_LOCK_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#define logd_lock_init(l) pthread_mutex_init((l), NULL)
#define logd_lock_lock(l) pthread_mutex_lock(l)
#define logd_lock_unlock(l) pthread_mutex_unlock(l)
#endif
