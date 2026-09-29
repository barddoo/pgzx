#ifndef PGZX_AIO_HELPERS
#define PGZX_AIO_HELPERS

#include <stdint.h>

/*
 * PG18 async I/O shim.
 *
 * `PgAioResult`, `PgAioReturn` and `PgAioTargetData` contain C bitfields,
 * which zig's translate-c (0.15+) demotes to opaque types. The Zig side can
 * therefore not declare storage for a `PgAioReturn` nor read a result. This
 * shim owns that storage and exposes the handful of accessors the binding
 * needs, exactly like libpqsrv.c does for the inline libpq helpers.
 *
 * Everything here is only defined on PG18+, where storage/aio.h exists.
 */
#if PG_VERSION_NUM >= 180000

#include <postgres.h>
#include <storage/aio.h>

struct iovec;

/* Opaque storage for one in-flight IO: handles the PgAioHandle plus the
 * PgAioReturn the issuer must keep alive until the IO completes. */
typedef struct pgzx_aio pgzx_aio;

pgzx_aio *pgzx_aio_acquire(void);
void pgzx_aio_release(pgzx_aio *aio);

/* iovec array owned by the handle; *iovcnt receives its capacity. */
struct iovec *pgzx_aio_iovec(pgzx_aio *aio, int *iovcnt);

/* PGAIO_HF_REFERENCES_LOCAL when the buffers live in backend-local memory. */
void pgzx_aio_set_local(pgzx_aio *aio, bool local);

/* Bind the already-filled iovecs to a read on a virtual File. Returns 0 on
 * success; nonzero means the IO was not started and must still be released. */
int pgzx_aio_start_read_file(pgzx_aio *aio, File file, int iovcnt,
							 off_t offset, uint32 wait_event_info);

/* Block until completion. Returns a PgAioResultStatus value. */
int pgzx_aio_wait(pgzx_aio *aio);

int pgzx_aio_status(pgzx_aio *aio);
int32 pgzx_aio_result(pgzx_aio *aio);

#endif							/* PG_VERSION_NUM >= 180000 */

#endif							/* PGZX_AIO_HELPERS */
