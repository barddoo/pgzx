// SQL schema for the extension. `zig build` renders
// `char_count_zig--0.1.sql` from this declaration.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "char_count_zig", .func = functions.char_count_zig },
    },
};
