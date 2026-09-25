const std = @import("std");
const pgzx = @import("pgzx");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.PG_FUNCTION_V1("guc_bool", guc_bool);
    pgzx.PG_FUNCTION_V1("guc_int", guc_int);
    pgzx.PG_FUNCTION_V1("guc_string", guc_string);
    pgzx.PG_FUNCTION_V1("guc_enum", guc_enum);
    pgzx.PG_FUNCTION_V1("guc_get", guc_get);
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

// Check hook: reject an empty string. `checkErrMsg`/`checkErrHint` set the
// message Postgres reports when the hook returns false.
fn rejectEmpty(newval: *[*c]u8, extra: *?*anyopaque, source: pgzx.c.GucSource) bool {
    _ = extra;
    _ = source;
    if (newval.* == null or newval.*[0] == 0) {
        pgzx.guc.checkErrMsg("guc.sample_string must not be empty", .{});
        pgzx.guc.checkErrHint("Use RESET guc.sample_string to restore the default.", .{});
        return false;
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
        // Postgres validates min/max before running the check hook, so the
        // bounds must admit the values the hook is meant to clamp.
        .min_value = -100,
        .check_hook = pgzx.guc.checkIntHook(clampInt),
    });

    sample_string.register(.{
        .name = "guc.sample_string",
        .short_desc = "Sample string GUC",
        .initial_value = "hello",
        .check_hook = pgzx.guc.checkStringHook(rejectEmpty),
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

    // All variables are defined: from now on `guc.<typo>` is an error
    // instead of a silently created placeholder.
    pgzx.guc.markPrefixReserved("guc");
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

// Any setting by name, as text; NULL if it does not exist.
fn guc_get(name: [:0]const u8) !?[:0]const u8 {
    return pgzx.guc.getOption(name);
}

const Testsuite = struct {
    pub fn testDefaults() !void {
        try std.testing.expectEqual(false, sample_bool.value);
        try std.testing.expectEqual(@as(c_int, 42), sample_int.value);
        try std.testing.expectEqualStrings("hello", sample_string.value());
        try std.testing.expectEqual(@as(c_int, 2), sample_enum.value);
    }

    pub fn testSetOption() !void {
        try pgzx.guc.setOption("guc.sample_string", "from zig", .{ .local = true });
        try std.testing.expectEqualStrings("from zig", pgzx.guc.getOption("guc.sample_string").?);
    }

    pub fn testIntClamp() !void {
        pgzx.c.SetConfigOption("guc.sample_int", "-5", pgzx.c.PGC_USERSET, pgzx.c.PGC_S_SESSION);
        try std.testing.expectEqual(@as(c_int, 0), sample_int.value);
    }
};

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Testsuite});
}
