#ifndef PGZX_TUPLE_HELPERS
#define PGZX_TUPLE_HELPERS

#include <postgres.h>
#include <access/tupdesc.h>

/*
 * BlessTupleDesc(): register an anonymous record descriptor.
 *
 * It is declared in funcapi.h, which cannot be included in the translated
 * headers: translate-c attaches extract_variadic_args() to
 * FunctionCallInfoBaseData as a declaration named `args`, which clashes with
 * that struct's `args` member. This wrapper lives in a C file that can
 * include funcapi.h.
 */
TupleDesc	pgzx_bless_tupdesc(TupleDesc tupdesc);

#endif							/* PGZX_TUPLE_HELPERS */
