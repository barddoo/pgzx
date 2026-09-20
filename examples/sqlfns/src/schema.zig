// SQL schema for the extension.
//
// `zig build` runs a small generator that imports this file and renders
// `sqlfns--0.1.sql` from `pgzx_sql`. Argument types are derived from the Zig
// signatures; the raw C function uses `args`/`returns` because its type
// information is not available.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "hello_world_c", .func = functions.hello_world_c, .args = &.{"text"}, .returns = "text" },
        .{ .name = "hello_world_zig", .func = functions.hello_world_zig },
        .{ .name = "hello_world_zig_null", .func = functions.hello_world_zig_null },
        .{ .name = "hello_world_zig_datum", .func = functions.hello_world_zig_datum, .args = &.{"text"}, .returns = "text" },
        .{ .name = "hello_world_anon", .func = functions.anon_funcs.hello_world_anon },
        .{ .name = "hello_world_mod", .func = functions.mod_hello_world.hello_world_mod },
        .{ .name = "hello_world_file", .func = @import("hello_world.zig").hello_world_file },
    },
};
