// SQL schema for the extension. `zig build` renders
// `file_io--0.1.sql` from this declaration.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "file_io_roundtrip", .func = functions.file_io_roundtrip },
        .{ .name = "file_io_truncate", .func = functions.file_io_truncate },
    },
};
