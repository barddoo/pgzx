#include <postgres.h>

#include <access/tupdesc.h>
#include <funcapi.h>

#include "include/tuple_helpers.h"

TupleDesc
pgzx_bless_tupdesc(TupleDesc tupdesc)
{
	return BlessTupleDesc(tupdesc);
}
