CREATE EXTENSION compress_zig;

SET search_path TO compress_zig;

-- A table that exercises each codec family:
--   id      monotonic   -> delta
--   device  low-card    -> rle / dict
--   reading floats      -> gorilla / dict
--   label   text        -> dictionary / plain
--   ok      boolean     -> bitmap
CREATE TABLE events (
    id bigint,
    device int,
    reading float8,
    label text,
    ok boolean
);

INSERT INTO events VALUES
    (1, 1, 1.5,  'alpha', true),
    (2, 1, 1.5,  'alpha', false),
    (3, 2, 2.25, 'beta',  true),
    (4, 2, 2.25, 'beta',  false),
    (5, 3, 3.5,  'gamma', true),
    (6, 3, NULL, NULL,    NULL);

SELECT compress_table('events');
SELECT batch_count('events');
SELECT decompress_table('events');

-- The decompressed JSON can be queried like a table, including NULLs.
SELECT (obj->>'id')::bigint AS id, obj->>'label' AS label, obj->>'reading' AS reading
FROM jsonb_array_elements(decompress_table('events')::jsonb) AS obj
ORDER BY 1;

-- Compressing again is idempotent (the previous batches are replaced).
SELECT compress_table('events');
SELECT batch_count('events');

-- The source table is left untouched.
SELECT count(*) FROM events;

DROP TABLE events;
DROP EXTENSION compress_zig;
