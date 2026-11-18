// SQL schema for the triggers example extension.
//
// `zig build` runs a generator that imports this file and renders
// `triggers--0.1.sql` from `pgzx_sql`.

const trigger_fns = @import("trigger_fns.zig");

pub const pgzx_sql = .{
    .sql =
    \\CREATE TABLE products (
    \\    id   serial PRIMARY KEY,
    \\    name text NOT NULL
    \\);
    \\
    ,
    .functions = .{
        .{ .name = "upcase_name", .func = trigger_fns.upcase_name, .returns = "trigger" },
    },
    .triggers = .{
        .{
            .name = "upcase_name_trigger",
            .func = "upcase_name",
            .table = "products",
            .timing = .before,
            .events = &[_]@import("pgzx").ddl.TriggerEvent{ .insert, .update },
            .level = .row,
        },
    },
};
