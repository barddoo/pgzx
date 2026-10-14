CREATE EXTENSION srf;

SET search_path TO srf;

-- SETOF bigint: default step, explicit step, empty set
SELECT * FROM srf_series(1, 5);
SELECT * FROM srf_series(1, 10, 3);
SELECT * FROM srf_series(5, 1);

-- as a scalar in the target list, and per-row via LATERAL
SELECT srf_series(1, 3);
SELECT s FROM generate_series(1, 3) AS g(n), LATERAL srf_series(g.n, 3) AS s;

-- invalid step raises an error on the first call
SELECT * FROM srf_series(1, 5, 0);

-- TABLE(id, val)
SELECT * FROM srf_series_table(1, 5, 2);

-- TABLE(index, value): the values are random, so assert shape deterministically
SELECT count(*) FROM srf_random_values(10);
SELECT count(*) FROM srf_random_values(10) WHERE value >= 0 AND value < 1;
SELECT * FROM srf_random_values(0);

-- TABLE(a, b) with nullable columns
SELECT * FROM srf_result_table();

-- single-column TABLE(a)
SELECT * FROM srf_one_col();

DROP EXTENSION srf;
