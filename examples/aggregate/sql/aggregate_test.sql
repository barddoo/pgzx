CREATE EXTENSION aggregate;

CREATE TEMP TABLE samples (grp int, x float8);
INSERT INTO samples VALUES (1, 2), (1, 8), (2, 3), (2, NULL), (2, 27);

-- geometric mean of 2 and 8 is 4
SELECT round(geomean(x)::numeric, 6) FROM samples WHERE grp = 1;

-- NULL inputs are skipped: geometric mean of 3 and 27 is 9
SELECT round(geomean(x)::numeric, 6) FROM samples WHERE grp = 2;

-- no rows aggregated: NULL
SELECT geomean(x) FROM samples WHERE false;

SELECT grp, round(geomean(x)::numeric, 3) FROM samples GROUP BY grp ORDER BY grp;

-- non-positive input is rejected
SELECT geomean(x) FROM (VALUES (-1.0::float8)) AS v(x);

DROP EXTENSION aggregate;
