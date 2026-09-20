CREATE EXTENSION rational;
SET search_path TO rational;

-- Parsing and normalization -------------------------------------------------
-- Every value is reduced to lowest terms with a positive denominator, so the
-- text form is canonical and `=` is representation independent.
SELECT '3/4'::rational AS value;
SELECT '6/8'::rational AS reduced;
SELECT '-6/8'::rational AS negative;
SELECT '3'::rational AS whole;

-- Arithmetic -----------------------------------------------------------------
SELECT '1/2'::rational + '1/3'::rational AS sum;
SELECT '1/2'::rational - '1/3'::rational AS difference;
SELECT '2/3'::rational * '3/4'::rational AS product;
SELECT '1/2'::rational / '1/4'::rational AS quotient;
SELECT -('-3/4'::rational) AS negated;
SELECT abs('-2/3'::rational) AS absolute_value;
SELECT rational(6, 8) AS constructed;

-- Comparison -----------------------------------------------------------------
SELECT '3/4'::rational = '6/8'::rational AS equal;
SELECT '1/2'::rational < '2/3'::rational AS less;
SELECT '3/4'::rational >= '3/4'::rational AS greater_or_equal;

-- Casts ----------------------------------------------------------------------
SELECT '1/8'::rational::float8 AS as_float8;
SELECT '5/10'::text::rational AS parsed_from_text;
SELECT ('1/2'::rational)::text AS rendered_as_text;

-- Type metadata: fixed length, pass by reference, 8 byte aligned, not TOASTed.
SELECT typname, typlen, typbyval, typalign, typstorage, typcategory
FROM pg_type
WHERE typname = 'rational';

-- Both operator classes are registered and one per access method is default.
SELECT am.amname, oc.opcname, oc.opcdefault
FROM pg_opclass oc
JOIN pg_am am ON am.oid = oc.opcmethod
WHERE oc.opcintype = 'rational'::regtype
ORDER BY am.amname;

-- Values in a table: ORDER BY, DISTINCT and GROUP BY are all driven by the
-- btree/hash opclasses.
CREATE TABLE fractions (v rational);
INSERT INTO fractions VALUES
    ('3/4'), ('1/2'), ('2/3'), ('1/4'), ('1/1'), ('2/4');

SELECT v FROM fractions ORDER BY v;
SELECT DISTINCT v FROM fractions ORDER BY v;

-- GROUP BY can use the hash opclass (hash aggregate) or the btree opclass.
SELECT v, count(*) AS n FROM fractions GROUP BY v ORDER BY v;

-- Range queries are evaluated correctly once the btree opclass exists.
SELECT count(*) AS in_range
FROM fractions
WHERE v BETWEEN '1/2' AND '3/4';

-- Creating the index exercises rational_ops. Turning off sequential scans
-- forces the index path, so these results also prove the comparison function
-- is correct.
CREATE INDEX fractions_v_idx ON fractions USING btree (v);
SET enable_seqscan = off;
SELECT v FROM fractions WHERE v = '1/2';
SELECT v FROM fractions WHERE v >= '1/2' AND v <= '2/3' ORDER BY v;
RESET enable_seqscan;

-- Binary representation is not implemented for this type, so it only speaks
-- the text I/O protocol.

DROP TABLE fractions;
DROP EXTENSION rational;
