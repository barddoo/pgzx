#include <postgres.h>

#include <fmgr.h>
#include <funcapi.h>
#include <nodes/execnodes.h>

#include "include/srf_helpers.h"

#define CX(cx) ((FuncCallContext *) (cx))

bool
pgzx_srf_is_first_call(FunctionCallInfo fcinfo)
{
	return SRF_IS_FIRSTCALL();
}

void
pgzx_srf_check_context(FunctionCallInfo fcinfo)
{
	ReturnSetInfo *rsi = (ReturnSetInfo *) fcinfo->resultinfo;

	if (rsi == NULL || !IsA(rsi, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsi->allowedModes & SFRM_ValuePerCall))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("value per call mode required, but it is not allowed in this context")));
}

pgzx_srf_cx *
pgzx_srf_init(FunctionCallInfo fcinfo)
{
	return (pgzx_srf_cx *) SRF_FIRSTCALL_INIT();
}

pgzx_srf_cx *
pgzx_srf_per_call(FunctionCallInfo fcinfo)
{
	return (pgzx_srf_cx *) SRF_PERCALL_SETUP();
}

MemoryContext
pgzx_srf_memctx(pgzx_srf_cx *cx)
{
	return CX(cx)->multi_call_memory_ctx;
}

void *
pgzx_srf_user(pgzx_srf_cx *cx)
{
	return CX(cx)->user_fctx;
}

void
pgzx_srf_set_user(pgzx_srf_cx *cx, void *user)
{
	CX(cx)->user_fctx = user;
}

void
pgzx_srf_return_next(FunctionCallInfo fcinfo, pgzx_srf_cx *cx)
{
	CX(cx)->call_cntr++;
	((ReturnSetInfo *) fcinfo->resultinfo)->isDone = ExprMultipleResult;
	fcinfo->isnull = false;
}

void
pgzx_srf_return_done(FunctionCallInfo fcinfo, pgzx_srf_cx *cx)
{
	end_MultiFuncCall(fcinfo, CX(cx));
	((ReturnSetInfo *) fcinfo->resultinfo)->isDone = ExprEndResult;
	fcinfo->isnull = true;
}

int
pgzx_srf_result_tupdesc(FunctionCallInfo fcinfo, TupleDesc *tupdesc)
{
	Oid			typid;

	switch (get_call_result_type(fcinfo, &typid, tupdesc))
	{
		case TYPEFUNC_SCALAR:
			return PGZX_SRF_RESULT_SCALAR;
		case TYPEFUNC_COMPOSITE:
		case TYPEFUNC_COMPOSITE_DOMAIN:
			*tupdesc = BlessTupleDesc(*tupdesc);
			return PGZX_SRF_RESULT_COMPOSITE;
		default:
			return PGZX_SRF_RESULT_OTHER;
	}
}
