const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("file_io_roundtrip", functions.file_io_roundtrip);
    pgzx.PG_FUNCTION_V1("file_io_truncate", functions.file_io_truncate);
}

comptime {
    pgzx.testing.registerTests(
        @import("build_options").testfn,
        .{functions.Testsuite},
    );
}
