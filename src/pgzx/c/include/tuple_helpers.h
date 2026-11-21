#ifndef PGZX_TUPLE_HELPERS
#define PGZX_TUPLE_HELPERS

#include <postgres.h>
#include <access/htup.h>
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

/*
 * TupleDescData accessors.
 *
 * PostgreSQL 19 added bitfields to CompactAttribute, which makes translate-c
 * demote the struct to opaque; the translated struct_TupleDescData then has an
 * array of opaque elements and cannot be instantiated. Zig reads the fields it
 * needs through these wrappers instead.
 */
int			pgzx_tupdesc_natts(TupleDesc tupdesc);
Oid			pgzx_tupdesc_typeid(TupleDesc tupdesc);
int32		pgzx_tupdesc_typmod(TupleDesc tupdesc);
int			pgzx_tupdesc_refcount(TupleDesc tupdesc);
FormData_pg_attribute *pgzx_tupdesc_attr(TupleDesc tupdesc, int i);

/*
 * heap_getattr(): call the C inline directly.
 *
 * On PG19 the inline body uses CompactAttribute, TupleDescCompactAttr() and
 * fetchatt(), which translate-c cannot translate, so the translated
 * heap_getattr() ends up calling an out-of-line `fastgetattr` symbol that the
 * server does not export. The C compiler inlines both here instead.
 */
Datum		pgzx_heap_getattr(HeapTuple tup, int attnum, TupleDesc tupdesc,
							 bool *isnull);

#endif							/* PGZX_TUPLE_HELPERS */
