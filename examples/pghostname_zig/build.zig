const std = @import("std");

// Load pgzx build support. The build utilities use pg_config to find all dependencies
// and provide functions go create and test extensions.
const PGBuild = @import("pgzx").Build;

pub fn build(b: *std.Build) void {
    const proj = PGBuild.Project.init(b, .{
        .name = "pghostname_zig",
        .version = .{ .major = 0, .minor = 1 },
        .root_dir = "src/",
        .root_source_file = "src/main.zig",
    });

    _ = proj.addSteps(.{
        .pg_regress = .{
            .db_user = "postgres",
            .db_port = 5432,
            .scripts = &[_][]const u8{"pghostname_zig_test"},
        },
        .unit = .{
            .db_user = "postgres",
            .db_port = 5432,
        },
    });
}
