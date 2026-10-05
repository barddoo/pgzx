#include <postgres.h>

#include <storage/spin.h>

#include "include/spin_helpers.h"

void
pgzx_spin_init(slock_t *lock)
{
	SpinLockInit(lock);
}

void
pgzx_spin_acquire(slock_t *lock)
{
	SpinLockAcquire(lock);
}

void
pgzx_spin_release(slock_t *lock)
{
	SpinLockRelease(lock);
}

bool
pgzx_spin_is_free(slock_t *lock)
{
#if PG_VERSION_NUM >= 190000
	return true;
#else
	return SpinLockFree(lock);
#endif
}
