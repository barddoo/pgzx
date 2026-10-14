#ifndef PGZX_SRF_HELPERS
#define PGZX_SRF_HELPERS

#include <postgres.h>
#include <fmgr.h>
#include <access/tupdesc.h>
#include <utils/palloc.h>

/*
 * Set-returning function (value-per-call) shim.
 *
 * funcapi.h cannot be included in the translated headers: translate-c
 * attaches extract_variadic_args() to FunctionCallInfoBaseData as a
 * declaration named `args`, which clashes with that struct's `args` member.
 * The SRF_* macros and FuncCallContext also cannot be used from Zig. These
 * wrappers expose the multi-call protocol with an opaque context handle.
 */
typedef struct pgzx_srf_cx pgzx_srf_cx;

/* Kinds of result type reported by pgzx_srf_result_tupdesc(). */
#define PGZX_SRF_RESULT_SCALAR		0
#define PGZX_SRF_RESULT_COMPOSITE	1
#define PGZX_SRF_RESULT_OTHER		2

/* SRF_IS_FIRSTCALL() */
bool		pgzx_srf_is_first_call(FunctionCallInfo fcinfo);

/* ereport(ERROR) unless the caller accepts a value-per-call set. */
void		pgzx_srf_check_context(FunctionCallInfo fcinfo);

/* SRF_FIRSTCALL_INIT() */
pgzx_srf_cx *pgzx_srf_init(FunctionCallInfo fcinfo);

/* SRF_PERCALL_SETUP() */
pgzx_srf_cx *pgzx_srf_per_call(FunctionCallInfo fcinfo);

MemoryContext pgzx_srf_memctx(pgzx_srf_cx *cx);
void	   *pgzx_srf_user(pgzx_srf_cx *cx);
void		pgzx_srf_set_user(pgzx_srf_cx *cx, void *user);

/* SRF_RETURN_NEXT(): the caller returns the datum afterwards. */
void		pgzx_srf_return_next(FunctionCallInfo fcinfo, pgzx_srf_cx *cx);

/* SRF_RETURN_DONE(): the caller returns a null datum afterwards. */
void		pgzx_srf_return_done(FunctionCallInfo fcinfo, pgzx_srf_cx *cx);

/*
 * get_call_result_type() plus BlessTupleDesc(). For a composite result the
 * blessed descriptor is stored in *tupdesc.
 */
int			pgzx_srf_result_tupdesc(FunctionCallInfo fcinfo, TupleDesc *tupdesc);

#endif							/* PGZX_SRF_HELPERS */
