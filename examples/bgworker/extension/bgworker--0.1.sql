\echo Use "CREATE EXTENSION bgworker" to load this file. \quit

CREATE FUNCTION pgzx_bgworker_roundtrip() RETURNS BOOLEAN
AS '$libdir/bgworker'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION pgzx_bgworker_double(BIGINT) RETURNS BIGINT
AS '$libdir/bgworker'
LANGUAGE C VOLATILE STRICT;
