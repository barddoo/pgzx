#ifndef PGZX_SPIN_HELPERS
#define PGZX_SPIN_HELPERS

#include <postgres.h>
#include <storage/spin.h>

/*
 * Spinlock shim.
 *
 * SpinLockInit/Acquire/Release are macros over S_LOCK/TAS, which expand to
 * inline assembly, __FILE__ and __func__. translate-c cannot translate them
 * and demotes `tas` to an unresolvable extern, so Zig cannot call the macros
 * directly. These wrappers are real symbols that Zig can link against.
 */
void pgzx_spin_init(slock_t *lock);
void pgzx_spin_acquire(slock_t *lock);
void pgzx_spin_release(slock_t *lock);

/* SpinLockFree() was removed in PG19; always reports "free" there. */
bool pgzx_spin_is_free(slock_t *lock);

#endif							/* PGZX_SPIN_HELPERS */
