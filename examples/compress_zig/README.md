# compress_zig - On-disk columnar compression example

This example shows how to build a small Timescale-style compression layer as a
pgzx extension. It compresses any heap table into encoded, type-aware column
batches stored in a sidecar relation, and decompresses them back to rows.

It is deliberately an example, not a drop-in Timescale: it does not install a
custom table access method or a planner hook, so decompression is an explicit
function call rather than transparent querying.

## What it demonstrates

- A columnar **on-disk batch format** (`src/compression.zig`): a 16-byte header,
  a per-column directory with absolute offsets, separate null bitmaps, and the
  encoded column streams.
- **Column encodings** (`src/compression/encoding.zig`): `plain`, `rle`,
  `delta`, `delta2`, `gorilla` (floats), `dictionary`, and bit-packed `bool`.
  The encoder tries every applicable codec and keeps the smallest.
- Building batches from a real table with **SPI**, storing each batch as a
  `bytea` row, and decoding it back to JSON rows.

## Layout

```
src/compression.zig          batch format (header, directory, null bitmaps)
src/compression/bytes.zig    little-endian writer/reader, varints, zig-zag
src/compression/encoding.zig column codecs and encoding selection
src/functions.zig            SQL functions (compress_table, decompress_table, ...)
src/schema.zig               generated extension SQL
```

`src/compression*` is pure Zig with no Postgres dependency, so it is unit
tested directly:

```sh
zig test src/compression.zig
```

## Usage

```sh
zig build -p "$PG_HOME"
psql -U postgres -c 'CREATE EXTENSION compress_zig'
```

```sql
CREATE TABLE events (id bigint, device int, reading float8, label text, ok boolean);
INSERT INTO events SELECT g, g % 4, g * 0.5, 'dev-' || (g % 4), g % 2 = 0
FROM generate_series(1, 100000) AS g;

SELECT compress_table('events');     -- rows written
SELECT batch_count('events');        -- one row per encoded batch
SELECT compressed_size('events');

-- Query the compressed data:
SELECT obj->>'id', obj->>'label'
FROM jsonb_array_elements(decompress_table('events')::jsonb) AS obj
LIMIT 5;
```

## Notes and limitations

- The sidecar relation `_compress_zig.batches` is created lazily by
  `compress_table` and is not dropped with the extension.
- The whole relation is buffered while compressing; this is fine for an example
  but a production implementation would stream batches.
- Decompression returns JSON rather than a `SETOF record`, because pgzx does
  not yet wrap materialized set-returning functions. A real extension would use
  a custom scan or a table access method for transparent reads.
- Only a handful of types are special-cased; anything else is stored as its
  text representation (`bytes`).
