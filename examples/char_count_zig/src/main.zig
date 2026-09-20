const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("char_count_zig", functions.char_count_zig);
}

comptime {
    pgzx.testing.registerTests(
        @import("build_options").testfn,
        .{ functions.Testsuite1, functions.Testsuite2 },
    );
}
