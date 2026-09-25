# spi - Server Programming Interface

A port of pgrx's [`pgrx-examples/spi`](https://github.com/pgcentralfoundation/pgrx/tree/develop/pgrx-examples/spi),
extended with the rest of `pgzx.spi`:

| Function | Shows |
|---|---|
| `spi_query_title`, `spi_query_by_id`, `spi_insert_title` | queries with arguments, typed rows, `RETURNING` |
| `issue1209_fixed` | a large `Cursor.fetch` |
| `spi_title_by_id_cached` | a `Plan` prepared once and kept for the session (`Plan.keep`) |
| `spi_cursor_count(query, batch DEFAULT 1000)` | fetching a cursor in batches |
| `spi_insert_titles(text[])` | `spi.subtransaction`: each insert runs like a PL/pgSQL `BEGIN ... EXCEPTION` block, failures are skipped with the error message |
| `spi_count_titles` | `SECURITY DEFINER` with a pinned `search_path` |

```zig
spi.subtransaction(insertOne, .{title}, .{ .error_data = &edata }) catch |e| {
    const data = edata orelse return e;
    defer pg.FreeErrorData(data);
    pgzx.elog.Notice(@src(), "skipped \"{s}\": {s}", .{ title, std.mem.span(data.*.message) });
    continue;
};
```

Values read through SPI live in the SPI procedure context, which
`spi.finish` frees, so text results are copied into the caller's memory
context before they are returned (`dupeInto` in `src/functions.zig`).

Not ported (not yet supported by pgzx): `spi_return_query` and
`spi_insert_title2`, which return tables.

```
zig build -p "$PG_HOME"   # build and install
./ci/run.sh               # build, install and run the regression tests
```
