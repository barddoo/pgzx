const std = @import("std");
const pgzx = @import("pgzx");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("guc_bool", guc_bool);
    pgzx.PG_FUNCTION_V1("guc_int", guc_int);
    pgzx.PG_FUNCTION_V1("guc_string", guc_string);
    pgzx.PG_FUNCTION_V1("guc_enum", guc_enum);
}

// Custom GUCs, registered in _PG_init.
var sample_bool: pgzx.guc.CustomBoolVariable = undefined;
var sample_int: pgzx.guc.CustomIntVariable = undefined;
var sample_string: pgzx.guc.CustomStringVariable = undefined;
var sample_enum: pgzx.guc.CustomEnumVariable = undefined;

// Check hook: clamp the integer GUC to [0, 100].
fn clampInt(newval: *c_int, extra: *?*anyopaque, source: pgzx.c.GucSource) bool {
    _ = extra;
    _ = source;
    if (newval.* < 0) {
        newval.* = 0;
    }
    if (newval.* > 100) {
        newval.* = 100;
    }
    return true;
}

pub export fn _PG_init() void {
    sample_bool.register(.{
        .name = "guc.sample_bool",
        .short_desc = "Sample boolean GUC",
        .initial_value = false,
    });

    sample_int.register(.{
        .name = "guc.sample_int",
        .short_desc = "Sample integer GUC",
        .initial_value = 42,
        .check_hook = pgzx.guc.checkIntHook(clampInt),
    });

    sample_string.register(.{
        .name = "guc.sample_string",
        .short_desc = "Sample string GUC",
        .initial_value = "hello",
    });

    sample_enum.register(.{
        .name = "guc.sample_enum",
        .short_desc = "Sample enum GUC",
        .values = &.{
            .{ .name = "small", .value = 1 },
            .{ .name = "medium", .value = 2 },
            .{ .name = "large", .value = 3 },
        },
        .initial_value = 2,
    });
}

fn guc_bool() ![:0]const u8 {
    return if (sample_bool.value) "on" else "off";
}

fn guc_int() !i32 {
    return sample_int.value;
}

fn guc_string() ![:0]const u8 {
    return sample_string.value();
}

fn guc_enum() ![:0]const u8 {
    return switch (sample_enum.value) {
        1 => "small",
        2 => "medium",
        3 => "large",
        else => "unknown",
    };
}

const Testsuite = struct {
    pub fn testDefaults() !void {
        try std.testing.expectEqual(false, sample_bool.value);
        try std.testing.expectEqual(@as(c_int, 42), sample_int.value);
        try std.testing.expectEqualStrings("hello", sample_string.value());
        try std.testing.expectEqual(@as(c_int, 2), sample_enum.value);
    }

    pub fn testIntClamp() !void {
        pgzx.c.SetConfigOption("guc.sample_int", "-5", pgzx.c.PGC_USERSET, pgzx.c.PGC_S_SESSION);
        try std.testing.expectEqual(@as(c_int, 0), sample_int.value);
    }
};

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Testsuite});
}
