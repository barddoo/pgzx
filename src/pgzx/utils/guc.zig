const std = @import("std");

const pg = @import("pgzx_pgsys");
const mem = @import("../mem.zig");

// ---------------------------------------------------------------------------
// Hook trampolines
//
// GUC hooks are C function pointers (see utils/guc.h). These helpers adapt a
// plain Zig function (no `callconv(.c)`, natural pointer types) into the C
// hook pointer that `DefineCustom*Variable` expects, following the same idiom
// as `bgworker.sigFlagHandler`.
// ---------------------------------------------------------------------------

/// Adapts `f(newval: *bool, extra: *?*anyopaque, source: pg.GucSource) bool`
/// into a `GucBoolCheckHook`.
pub inline fn checkBoolHook(comptime f: anytype) pg.GucBoolCheckHook {
    return struct {
        fn shim(newval: [*c]bool, extra: [*c]?*anyopaque, source: pg.GucSource) callconv(.c) bool {
            return f(@as(*bool, @ptrCast(newval)), @as(*?*anyopaque, @ptrCast(extra)), source);
        }
    }.shim;
}

/// Adapts `f(newval: *c_int, extra: *?*anyopaque, source: pg.GucSource) bool`
/// into a `GucIntCheckHook`.
pub inline fn checkIntHook(comptime f: anytype) pg.GucIntCheckHook {
    return struct {
        fn shim(newval: [*c]c_int, extra: [*c]?*anyopaque, source: pg.GucSource) callconv(.c) bool {
            return f(@as(*c_int, @ptrCast(newval)), @as(*?*anyopaque, @ptrCast(extra)), source);
        }
    }.shim;
}

/// Adapts `f(newval: *f64, extra: *?*anyopaque, source: pg.GucSource) bool`
/// into a `GucRealCheckHook`.
pub inline fn checkRealHook(comptime f: anytype) pg.GucRealCheckHook {
    return struct {
        fn shim(newval: [*c]f64, extra: [*c]?*anyopaque, source: pg.GucSource) callconv(.c) bool {
            return f(@as(*f64, @ptrCast(newval)), @as(*?*anyopaque, @ptrCast(extra)), source);
        }
    }.shim;
}

/// Adapts `f(newval: *c_int, extra: *?*anyopaque, source: pg.GucSource) bool`
/// into a `GucEnumCheckHook`.
pub inline fn checkEnumHook(comptime f: anytype) pg.GucEnumCheckHook {
    return struct {
        fn shim(newval: [*c]c_int, extra: [*c]?*anyopaque, source: pg.GucSource) callconv(.c) bool {
            return f(@as(*c_int, @ptrCast(newval)), @as(*?*anyopaque, @ptrCast(extra)), source);
        }
    }.shim;
}

/// Adapts `f(newval: bool, extra: ?*anyopaque) void` into a `GucBoolAssignHook`.
pub inline fn assignBoolHook(comptime f: anytype) pg.GucBoolAssignHook {
    return struct {
        fn shim(newval: bool, extra: ?*anyopaque) callconv(.c) void {
            f(newval, extra);
        }
    }.shim;
}

/// Adapts `f(newval: c_int, extra: ?*anyopaque) void` into a `GucIntAssignHook`.
pub inline fn assignIntHook(comptime f: anytype) pg.GucIntAssignHook {
    return struct {
        fn shim(newval: c_int, extra: ?*anyopaque) callconv(.c) void {
            f(newval, extra);
        }
    }.shim;
}

/// Adapts `f(newval: f64, extra: ?*anyopaque) void` into a `GucRealAssignHook`.
pub inline fn assignRealHook(comptime f: anytype) pg.GucRealAssignHook {
    return struct {
        fn shim(newval: f64, extra: ?*anyopaque) callconv(.c) void {
            f(newval, extra);
        }
    }.shim;
}

/// Adapts `f(newval: []const u8, extra: ?*anyopaque) void` into a `GucStringAssignHook`.
pub inline fn assignStringHook(comptime f: anytype) pg.GucStringAssignHook {
    return struct {
        fn shim(newval: [*c]const u8, extra: ?*anyopaque) callconv(.c) void {
            f(std.mem.span(newval), extra);
        }
    }.shim;
}

/// Adapts `f(newval: c_int, extra: ?*anyopaque) void` into a `GucEnumAssignHook`.
pub inline fn assignEnumHook(comptime f: anytype) pg.GucEnumAssignHook {
    return struct {
        fn shim(newval: c_int, extra: ?*anyopaque) callconv(.c) void {
            f(newval, extra);
        }
    }.shim;
}

/// Adapts `f() [:0]const u8` into a `GucShowHook`. The returned string must
/// remain valid for the lifetime of the process (e.g. a static string).
pub inline fn showHook(comptime f: anytype) pg.GucShowHook {
    return struct {
        fn shim() callconv(.c) [*c]const u8 {
            return f().ptr;
        }
    }.shim;
}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

pub const CustomBoolVariable = struct {
    value: bool,

    pub const Options = struct {
        name: [:0]const u8,
        short_desc: ?[:0]const u8 = null,
        long_desc: ?[:0]const u8 = null,
        initial_value: bool = false,
        context: pg.GucContext = pg.PGC_USERSET,
        flags: c_int = 0,
        check_hook: pg.GucBoolCheckHook = null,
        assign_hook: pg.GucBoolAssignHook = null,
        show_hook: pg.GucShowHook = null,
    };

    pub fn registerValue(options: Options) void {
        doRegister(null, options);
    }

    pub fn register(self: *CustomBoolVariable, options: Options) void {
        self.value = options.initial_value;
        doRegister(&self.value, options);
    }

    fn doRegister(value: ?*bool, options: Options) void {
        pg.DefineCustomBoolVariable(
            options.name,
            optSliceCPtr(options.short_desc),
            optSliceCPtr(options.long_desc),
            value,
            options.initial_value,
            options.context,
            options.flags,
            options.check_hook,
            options.assign_hook,
            options.show_hook,
        );
    }
};

pub const CustomIntVariable = struct {
    value: c_int,

    pub const Options = struct {
        name: [:0]const u8,
        short_desc: ?[:0]const u8 = null,
        long_desc: ?[:0]const u8 = null,
        initial_value: ?c_int = 0,
        min_value: c_int = 0,
        max_value: c_int = std.math.maxInt(c_int),
        context: pg.GucContext = pg.PGC_USERSET,
        flags: c_int = 0,
        check_hook: pg.GucIntCheckHook = null,
        assign_hook: pg.GucIntAssignHook = null,
        show_hook: pg.GucShowHook = null,
    };

    pub fn registerValue(options: Options) void {
        doRegister(null, options);
    }

    pub fn register(self: *CustomIntVariable, options: Options) void {
        if (options.initial_value) |v| {
            self.value = v;
        }
        doRegister(&self.value, options);
    }

    fn doRegister(value: ?*c_int, options: Options) void {
        const init_value = if (value) |v| v.* else options.initial_value orelse 0;
        pg.DefineCustomIntVariable(
            options.name,
            optSliceCPtr(options.short_desc),
            optSliceCPtr(options.long_desc),
            value,
            init_value,
            options.min_value,
            options.max_value,
            options.context,
            options.flags,
            options.check_hook,
            options.assign_hook,
            options.show_hook,
        );
    }
};

pub const CustomRealVariable = struct {
    value: f64,

    pub const Options = struct {
        name: [:0]const u8,
        short_desc: ?[:0]const u8 = null,
        long_desc: ?[:0]const u8 = null,
        initial_value: f64 = 0,
        min_value: f64 = 0,
        max_value: f64 = std.math.floatMax(f64),
        context: pg.GucContext = pg.PGC_USERSET,
        flags: c_int = 0,
        check_hook: pg.GucRealCheckHook = null,
        assign_hook: pg.GucRealAssignHook = null,
        show_hook: pg.GucShowHook = null,
    };

    pub fn registerValue(options: Options) void {
        doRegister(null, options);
    }

    pub fn register(self: *CustomRealVariable, options: Options) void {
        self.value = options.initial_value;
        doRegister(&self.value, options);
    }

    fn doRegister(value: ?*f64, options: Options) void {
        pg.DefineCustomRealVariable(
            options.name,
            optSliceCPtr(options.short_desc),
            optSliceCPtr(options.long_desc),
            value,
            options.initial_value,
            options.min_value,
            options.max_value,
            options.context,
            options.flags,
            options.check_hook,
            options.assign_hook,
            options.show_hook,
        );
    }
};

pub const CustomStringVariable = struct {
    _value: [*c]const u8 = null,

    pub const Options = struct {
        name: [:0]const u8,
        short_desc: ?[:0]const u8 = null,
        long_desc: ?[:0]const u8 = null,
        initial_value: ?[:0]const u8 = null,
        context: pg.GucContext = pg.PGC_USERSET,
        flags: c_int = 0,
        check_hook: pg.GucStringCheckHook = null,
        assign_hook: pg.GucStringAssignHook = null,
        show_hook: pg.GucShowHook = null,
    };

    pub fn registerValue(options: Options) void {
        doRegister(null, options);
    }

    pub fn register(self: *CustomStringVariable, options: Options) void {
        if (options.initial_value) |v| {
            self._value = v.ptr;
        }
        doRegister(@ptrCast(&self._value), options);
    }

    fn doRegister(value_addr: [*c][*c]u8, options: Options) void {
        const boot = if (options.initial_value) |v| v.ptr else null;
        pg.DefineCustomStringVariable(
            options.name,
            optSliceCPtr(options.short_desc),
            optSliceCPtr(options.long_desc),
            value_addr,
            boot,
            options.context,
            options.flags,
            options.check_hook,
            options.assign_hook,
            options.show_hook,
        );
    }

    pub fn ptr(self: *CustomStringVariable) [*c]const u8 {
        return self._value;
    }

    pub fn value(self: *CustomStringVariable) [:0]const u8 {
        if (self._value == null) {
            return "";
        }

        // TODO: use assign callback to precompute the length
        return std.mem.span(self._value);
    }
};

pub const CustomEnumVariable = struct {
    value: c_int,

    pub const EnumValue = struct {
        name: [:0]const u8,
        value: c_int,
    };

    pub const Options = struct {
        name: [:0]const u8,
        values: []const EnumValue,
        short_desc: ?[:0]const u8 = null,
        long_desc: ?[:0]const u8 = null,
        initial_value: c_int = 0,
        context: pg.GucContext = pg.PGC_USERSET,
        flags: c_int = 0,
        check_hook: pg.GucEnumCheckHook = null,
        assign_hook: pg.GucEnumAssignHook = null,
        show_hook: pg.GucShowHook = null,
    };

    pub fn registerValue(options: Options) void {
        doRegister(null, options);
    }

    pub fn register(self: *CustomEnumVariable, options: Options) void {
        self.value = options.initial_value;
        doRegister(&self.value, options);
    }

    fn doRegister(value: ?*c_int, options: Options) void {
        const entries = enumEntries(options.values);
        pg.DefineCustomEnumVariable(
            options.name,
            optSliceCPtr(options.short_desc),
            optSliceCPtr(options.long_desc),
            value,
            options.initial_value,
            entries.ptr,
            options.context,
            options.flags,
            options.check_hook,
            options.assign_hook,
            options.show_hook,
        );
    }

    /// Builds a NUL-terminated `config_enum_entry` array in `TopMemoryContext`
    /// so it stays valid for the lifetime of the process (GUC never frees it).
    fn enumEntries(values: []const EnumValue) []pg.struct_config_enum_entry {
        var top_alloc = mem.MemoryContextAllocator.init(pg.TopMemoryContext, .{});
        const entries = top_alloc.allocator().alloc(pg.struct_config_enum_entry, values.len + 1) catch unreachable;
        for (values, 0..) |v, i| {
            entries[i] = .{ .name = v.name.ptr, .val = v.value, .hidden = false };
        }
        entries[values.len] = .{ .name = null, .val = 0, .hidden = false };
        return entries;
    }
};

pub const CustomIntOptions = struct {
    name: [:0]const u8,
    short_desc: ?[:0]const u8 = null,
    long_desc: ?[:0]const u8 = null,
    value_addr: *c_int,
    boot_value: c_int = 0,
    min_value: c_int = 0,
    max_value: c_int = std.math.maxInt(c_int),
    context: pg.GucContext = pg.PGC_USERSET,
    flags: c_int = 0,
    check_hook: pg.GucIntCheckHook = null,
    assign_hook: pg.GucIntAssignHook = null,
    show_hook: pg.GucShowHook = null,
};

pub fn defineCustomInt(options: CustomIntOptions) void {
    pg.DefineCustomIntVariable(
        options.name,
        optSliceCPtr(options.short_desc),
        optSliceCPtr(options.long_desc),
        options.value_addr,
        options.boot_value,
        options.min_value,
        options.max_value,
        options.context,
        options.flags,
        options.check_hook,
        options.assign_hook,
        options.show_hook,
    );
}

fn optSliceCPtr(opt_slice: ?[:0]const u8) [*c]const u8 {
    if (opt_slice) |s| {
        return s.ptr;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

var test_int_assign_value: c_int = 0;

fn testIntAssignHook(newval: c_int, extra: ?*anyopaque) void {
    _ = extra;
    test_int_assign_value = newval;
}

pub const TestSuite_Guc = struct {
    pub fn testCustomBoolVariable() !void {
        CustomBoolVariable.registerValue(.{
            .name = "pgzx.test_bool",
            .short_desc = "pgzx unit test bool",
            .initial_value = false,
        });

        try std.testing.expectEqualStrings("off", std.mem.span(pg.GetConfigOption("pgzx.test_bool", false, false)));
        pg.SetConfigOption("pgzx.test_bool", "on", pg.PGC_USERSET, pg.PGC_S_SESSION);
        try std.testing.expectEqualStrings("on", std.mem.span(pg.GetConfigOption("pgzx.test_bool", false, false)));
    }

    pub fn testCustomIntVariableWithAssignHook() !void {
        CustomIntVariable.registerValue(.{
            .name = "pgzx.test_int",
            .short_desc = "pgzx unit test int",
            .initial_value = 0,
            .assign_hook = assignIntHook(testIntAssignHook),
        });

        pg.SetConfigOption("pgzx.test_int", "42", pg.PGC_USERSET, pg.PGC_S_SESSION);
        try std.testing.expectEqual(@as(c_int, 42), test_int_assign_value);
        try std.testing.expectEqualStrings("42", std.mem.span(pg.GetConfigOption("pgzx.test_int", false, false)));
    }
};
