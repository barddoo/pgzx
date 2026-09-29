#include <postgres.h>

#if PG_VERSION_NUM >= 180000

#include <storage/aio.h>
#include <storage/fd.h>
#include <utils/resowner.h>

#include "include/aio_helpers.h"

struct pgzx_aio
{
	PgAioHandle *ioh;
	PgAioReturn ret;
	PgAioWaitRef wref;
	bool		started;
};

pgzx_aio *
pgzx_aio_acquire(void)
{
	pgzx_aio  *aio = palloc(sizeof(*aio));

	/*
	 * pgaio_io_acquire() may block and may ereport(ERROR); the palloc'd
	 * storage is then reclaimed with the current memory context.
	 */
	aio->ioh = pgaio_io_acquire(CurrentResourceOwner, &aio->ret);
	aio->started = false;
	return aio;
}

void
pgzx_aio_release(pgzx_aio *aio)
{
	/*
	 * A successful pgaio_io_start_*() consumes the handle: it may no longer be
	 * referenced and is returned to the pool on completion. Only an IO that
	 * was never started can (must) be released explicitly.
	 */
	if (!aio->started && aio->ioh != NULL)
		pgaio_io_release(aio->ioh);
	pfree(aio);
}

struct iovec *
pgzx_aio_iovec(pgzx_aio *aio, int *iovcnt)
{
	struct iovec *iov = NULL;

	if (aio->ioh == NULL)
	{
		*iovcnt = 0;
		return NULL;
	}
	*iovcnt = pgaio_io_get_iovec(aio->ioh, &iov);
	return iov;
}

void
pgzx_aio_set_local(pgzx_aio *aio, bool local)
{
	if (local)
		pgaio_io_set_flag(aio->ioh, PGAIO_HF_REFERENCES_LOCAL);
}

int
pgzx_aio_start_read_file(pgzx_aio *aio, File file, int iovcnt,
						 off_t offset, uint32 wait_event_info)
{
	int			rc;

	if (aio->ioh == NULL)
		return -1;

	/*
	 * The wait reference must be taken *before* the IO is started: starting
	 * consumes the handle, which may then be reused.
	 */
	pgaio_io_get_wref(aio->ioh, &aio->wref);
	rc = FileStartReadV(aio->ioh, file, iovcnt, offset, wait_event_info);
	aio->started = (rc == 0);
	return rc;
}

int
pgzx_aio_wait(pgzx_aio *aio)
{
	pgaio_wref_wait(&aio->wref);
	return (int) aio->ret.result.status;
}

int
pgzx_aio_status(pgzx_aio *aio)
{
	return (int) aio->ret.result.status;
}

int32
pgzx_aio_result(pgzx_aio *aio)
{
	return aio->ret.result.result;
}

#endif							/* PG_VERSION_NUM >= 180000 */
