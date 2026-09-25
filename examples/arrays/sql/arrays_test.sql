CREATE EXTENSION arrays;

SET search_path TO arrays;

-- Ported from pgrx-examples/arrays
SELECT sq_euclid(ARRAY[1, 2, 3]::real[], ARRAY[4, 6, 3]::real[]);
SELECT sq_euclid(ARRAY[1]::real[], ARRAY[1, 2]::real[]);
SELECT sq_euclid(ARRAY[1, NULL]::real[], ARRAY[1, 2]::real[]);

SELECT approx_distance(ARRAY[0, 2, 2]::bigint[], ARRAY[0.5, 1.5, 2.5]::float8[]);
SELECT approx_distance(ARRAY[3]::bigint[], ARRAY[0.5]::float8[]);

SELECT default_array();
SELECT sum_array();
SELECT sum_array(ARRAY[1, 2, NULL, 4]);

SELECT sum_vec(ARRAY[1, 2, NULL]);

SELECT static_names();
SELECT i32_array_no_nulls();
SELECT i32_array_with_nulls();
SELECT strip_nulls(i32_array_with_nulls());
SELECT strip_nulls(ARRAY[]::integer[]);

SELECT sum_vector(ARRAY[0.5, 1.5, 2]::real[]);

-- Zero-copy view: same result; multi-dimensional arrays are flattened.
SELECT sum_vector_view(ARRAY[0.5, 1.5, 2]::real[]);
SELECT sum_vector_view(ARRAY[[1, 2], [3, 4]]::real[]);
SELECT sum_vector_view(ARRAY[]::real[]);
SELECT sum_vector_view(ARRAY[1, NULL]::real[]);

-- SIMD and fast-math variants: 16-lane blocks plus a scalar tail. Small
-- integers sum exactly, so every variant must agree.
SELECT n, sum_vector(a) AS plain, sum_vector_simd(a) AS simd, sum_vector_fastmath(a) AS fastmath
FROM (SELECT n, array_agg(i::real) AS a FROM generate_series(0, 40) n, generate_series(1, n) i GROUP BY n) s
WHERE n IN (1, 15, 16, 17, 32, 40)
ORDER BY n;

-- Beyond the pgrx example
SELECT sum_all(1, 2, 3, 4);
SELECT sum_all(VARIADIC ARRAY[10, 20]);

SELECT clamp_all(ARRAY[-5, 50, 500]);
SELECT clamp_all(ARRAY[-5, 50, 500], hi => 10);
SELECT clamp_all(ARRAY[-5, 50, 500], -1, 1);
SELECT clamp_all(ARRAY[1], 5, 1);

SELECT distinct_sorted(ARRAY[3, 1, 3, 2, 1]);

SELECT obj_description('clamp_all(integer[],integer,integer)'::regprocedure, 'pg_proc');
SELECT proname, procost, provolatile, proisstrict, proparallel
FROM pg_proc
WHERE proname IN ('distinct_sorted', 'approx_distance', 'sum_all')
ORDER BY proname;

DROP EXTENSION arrays;
