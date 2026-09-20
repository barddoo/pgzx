-- Catalog objects for the `rational` base type. The functions are generated
-- from schema.zig; everything that is not a CREATE FUNCTION lives here.
--
-- This is included after the generated functions, so `rational_in` and
-- `rational_out` already exist when the type is completed below.

-- Fixed length, by reference, so `typlen = 16`, `typbyval = false`.
CREATE TYPE rational (
    INTERNALLENGTH = 16,
    INPUT = rational_in,
    OUTPUT = rational_out,
    ALIGNMENT = double,
    STORAGE = plain,
    CATEGORY = 'N'
);

-- Operators. HASHES/MERGES on `=` let the planner consider hash and merge
-- joins once the opclasses below exist.
CREATE OPERATOR = (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_eq,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel,
    HASHES, MERGES
);

CREATE OPERATOR <> (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_ne,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);

CREATE OPERATOR < (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_lt,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);

CREATE OPERATOR <= (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_le,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);

CREATE OPERATOR > (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_gt,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);

CREATE OPERATOR >= (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_ge,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

CREATE OPERATOR + (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_add,
    COMMUTATOR = +
);

CREATE OPERATOR - (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_sub
);

CREATE OPERATOR * (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_mul,
    COMMUTATOR = *
);

CREATE OPERATOR / (
    LEFTARG = rational, RIGHTARG = rational, FUNCTION = rational_div
);

CREATE OPERATOR - (
    RIGHTARG = rational, FUNCTION = rational_neg
);

-- Default operator classes make `CREATE INDEX ... USING btree` and hash
-- aggregation/hash joins work out of the box.
CREATE OPERATOR CLASS rational_ops
    DEFAULT FOR TYPE rational USING btree AS
        OPERATOR 1 <,
        OPERATOR 2 <=,
        OPERATOR 3 =,
        OPERATOR 4 >=,
        OPERATOR 5 >,
        FUNCTION 1 rational_cmp(rational, rational);

CREATE OPERATOR CLASS rational_hash_ops
    DEFAULT FOR TYPE rational USING hash AS
        OPERATOR 1 =,
        FUNCTION 1 rational_hash(rational);

-- Casts. WITH INOUT routes through the type's own I/O functions.
CREATE CAST (text AS rational) WITH INOUT AS ASSIGNMENT;
CREATE CAST (rational AS text) WITH INOUT AS ASSIGNMENT;
CREATE CAST (rational AS float8)
    WITH FUNCTION rational_to_float8(rational) AS ASSIGNMENT;
