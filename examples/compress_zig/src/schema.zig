// SQL schema for the `compress_zig` example.
//
// `zig build` renders `compress_zig--0.1.sql` from this declaration. The
// sidecar relation used to store compressed batches is created lazily by
// `compress_table`, so there is no catalog.sql here.

const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "compress_table", .func = functions.compress_table },
        .{ .name = "decompress_table", .func = functions.decompress_table },
        .{ .name = "batch_count", .func = functions.batch_count },
        .{ .name = "compressed_size", .func = functions.compressed_size },
    },
};
