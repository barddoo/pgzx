// SQL schema of the `spi` extension; `zig build` renders `spi--0.1.sql`
// from it. `.sql` runs first and creates the example tables.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .sql =
    \\CREATE TABLE spi_example (
    \\    id serial8 NOT NULL PRIMARY KEY,
    \\    title text CHECK (title <> '')
    \\);
    \\
    \\INSERT INTO spi_example (title) VALUES ('This is a test');
    \\INSERT INTO spi_example (title) VALUES ('Hello There!');
    \\INSERT INTO spi_example (title) VALUES ('I like pudding');
    \\
    \\CREATE TABLE foo ();
    ,

    .functions = .{
        // Ported from pgrx-examples/spi
        .{ .name = "spi_query_random_id", .func = functions.spi_query_random_id },
        .{ .name = "spi_query_title", .func = functions.spi_query_title, .strict = true },
        .{ .name = "spi_query_by_id", .func = functions.spi_query_by_id, .strict = true },
        .{ .name = "spi_insert_title", .func = functions.spi_insert_title, .strict = true },
        .{ .name = "issue1209_fixed", .func = functions.issue1209_fixed },

        // Prepared plans, cursors, subtransactions
        .{ .name = "spi_title_by_id_cached", .func = functions.spi_title_by_id_cached, .strict = true, .volatility = .stable },
        .{
            .name = "spi_cursor_count",
            .func = functions.spi_cursor_count,
            .strict = true,
            .params = &.{
                .{ .name = "query" },
                .{ .name = "batch", .default = "1000" },
            },
        },
        .{ .name = "spi_insert_titles", .func = functions.spi_insert_titles, .strict = true },

        // SECURITY DEFINER with a pinned search_path
        .{
            .name = "spi_count_titles",
            .func = functions.spi_count_titles,
            .volatility = .stable,
            .security = .definer,
            .set = &.{.{ .name = "search_path", .value = "pg_catalog, pg_temp" }},
        },
    },
};
