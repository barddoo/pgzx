rational
========

A `rational` (fraction) base type implemented in Zig with pgzx.

This example is about the **PostgreSQL type system**, not about arithmetic. A
base type is just a set of catalog entries (`pg_type`, `pg_operator`,
`pg_opclass`, `pg_cast`, ...) that point at ordinary C-callable functions. Once
those entries exist the server treats the type as a first class citizen: it can
be indexed, sorted, grouped, hashed and cast.

## What the type does

```sql
SELECT '6/8'::rational;              -- 3/4   (reduced to lowest terms)
SELECT '1/2'::rational + '1/3'::rational;  -- 5/6
SELECT '1/2'::rational < '2/3'::rational;  -- t
SELECT ('1/8'::rational)::float8;    -- 0.125
```

Values are stored as a fixed 16 byte, pass-by-reference struct
(`{ int64 num, int64 den }`) with a positive, coprime denominator, so the text
form and the binary representation are canonical. That invariant is what makes
`=`, hashing and index ordering agree with each other.

## The catalog pieces

| Object | Purpose |
|---|---|
| `CREATE TYPE rational (... INPUT, OUTPUT ...)` | Defines the type. `INTERNALLENGTH = 16`, `ALIGNMENT = double`, `STORAGE = plain`, so `typlen = 16` and `typbyval = false` |
| `rational_in` / `rational_out` | Text I/O. Called by the type system, not by SQL expressions |
| `rational_eq/ne/lt/le/gt/ge` | The comparison operators |
| `rational_cmp` | `btree` support function returning `-1/0/1` |
| `rational_hash` | `hash` support function returning `int4` |
| `CREATE OPERATOR ...` | Binds operators such as `=` and `+` to functions |
| `CREATE OPERATOR CLASS ... USING btree` | Makes `CREATE INDEX ... USING btree`, `ORDER BY`, `BETWEEN`, `DISTINCT` work |
| `CREATE OPERATOR CLASS ... USING hash` | Makes hash aggregation and hash joins possible |
| `CREATE CAST ... WITH INOUT` | `text` <-> `rational` through the type's I/O functions |

## Why the shell type

`CREATE TYPE rational;` first creates a *shell* type. That lets the I/O
functions be declared with `RETURNS rational` before the full definition
exists. The shell is completed later by `CREATE TYPE rational (...)`.

A `LANGUAGE C` function named in a `CREATE TYPE` statement is called through
the normal fmgr interface, so the Zig functions use `PG_FUNCTION_V1` and pass
values around as `Datum`.

## Source layout and generated SQL

The SQL script is generated from a comptime declaration, so the example is
split across four files:

| File | Contents |
|---|---|
| `src/functions.zig` | Value logic and the C-callable functions. No registration and no exports, so the schema generator can introspect it without linking the server. |
| `src/schema.zig` | The `pgzx_sql` declaration: the shell type, the function list, and the embedded catalog. |
| `src/catalog.sql` | Raw SQL the generator does not model yet: the completed type, operators, opclasses and casts. |
| `src/main.zig` | Runtime registration (`PG_MODULE_MAGIC`, `PG_FUNCTION_V1`) and test registration. |

`zig build` renders `rational--0.1.sql` in this order: the shell type, then a
`CREATE FUNCTION` for every entry in `schema.zig`, then `catalog.sql`. The
shell type comes first so the I/O functions can return `rational`; the type is
completed in `catalog.sql` once `rational_in`/`rational_out` exist. Regenerate
and inspect the result with:

```sh
zig build sql
```

## Try it

```sh
cd examples/rational
zig build -p "$PG_HOME"
psql -U postgres -c 'CREATE EXTENSION rational'
psql -U postgres
```

```sql
SET search_path TO rational;

CREATE TABLE fractions (v rational);
INSERT INTO fractions VALUES ('3/4'), ('1/2'), ('2/3'), ('1/4'), ('2/4');

CREATE INDEX ON fractions USING btree (v);

-- Force the index path to prove the operator class is used.
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT v FROM fractions WHERE v = '1/2';
SELECT v FROM fractions WHERE v >= '1/2' ORDER BY v;
RESET enable_seqscan;

-- The hash opclass enables hash aggregation.
EXPLAIN (COSTS OFF) SELECT v, count(*) FROM fractions GROUP BY v;
```

## Tests

```sh
zig build unit -p "$PG_HOME"         # in-server unit tests of the value logic
zig build pg_regress -p "$PG_HOME"   # type, operators, opclasses, casts
```

The unit tests exercise the pure Zig logic (normalization, parsing, ordering,
hashing). The regression test is where the Postgres integration lives: it
inspects `pg_type` and `pg_opclass`, then builds a table and an index and runs
range/grouping queries.

## Things to explore

- Add `rational_recv`/`rational_send` so `COPY ... WITH (FORMAT binary)` works
  (needs `libpq/pqformat.h`).
- Add a `rational_numeric(rational)` cast and a `sum(rational)` aggregate.
- Add a `rational_typmod` input function to support `rational(denominator)`.
- Replace `normalize` with infinite precision (`numeric`) or use a
  pass-by-value 8 byte representation.
