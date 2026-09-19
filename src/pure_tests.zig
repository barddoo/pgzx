const std = @import("std");
const meta = @import("pgzx/meta.zig");

/// Runs every `test*` function declared in `S`.
///
/// This mirrors `testing.registerTests` discovery but works under `zig test`
/// for modules that do not depend on a live Postgres server. Add more suites
/// here as modules become free of `pgzx_pgsys`.
fn runSuite(comptime S: type) !void {
    inline for (comptime std.meta.declarations(S)) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "test")) {
            try @field(S, decl.name)();
        }
    }
}

test "meta" {
    try runSuite(meta.TestSuite_Meta);
}
