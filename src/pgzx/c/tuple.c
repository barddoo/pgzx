#include <postgres.h>

#include <access/htup_details.h>
#include <access/tupdesc.h>
#include <funcapi.h>

#include "include/tuple_helpers.h"

TupleDesc
pgzx_bless_tupdesc(TupleDesc tupdesc)
{
	return BlessTupleDesc(tupdesc);
}

int
pgzx_tupdesc_natts(TupleDesc tupdesc)
{
	return tupdesc->natts;
}

Oid
pgzx_tupdesc_typeid(TupleDesc tupdesc)
{
	return tupdesc->tdtypeid;
}

int32
pgzx_tupdesc_typmod(TupleDesc tupdesc)
{
	return tupdesc->tdtypmod;
}

int
pgzx_tupdesc_refcount(TupleDesc tupdesc)
{
	return tupdesc->tdrefcount;
}

FormData_pg_attribute *
pgzx_tupdesc_attr(TupleDesc tupdesc, int i)
{
	return TupleDescAttr(tupdesc, i);
}

Datum
pgzx_heap_getattr(HeapTuple tup, int attnum, TupleDesc tupdesc, bool *isnull)
{
	return heap_getattr(tup, attnum, tupdesc, isnull);
}
