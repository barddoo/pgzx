const std = @import("std");
const pgzx = @import("pgzx");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("hello", hello);
}

fn hello() ![:0]const u8 {
    return "Hello, world!";
}

const Tests = struct {
    pub fn testHello() !void {
        const message = try hello();
        try std.testing.expectEqualStrings("Hello, world!", message);
    }
};

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Tests});
}
