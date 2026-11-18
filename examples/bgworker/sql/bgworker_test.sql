CREATE EXTENSION bgworker;

SELECT pgzx_bgworker_roundtrip();

-- value passed through a dynamic shared memory segment and doubled by a worker
SELECT pgzx_bgworker_double(21);

DROP EXTENSION bgworker;
