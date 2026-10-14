//! Set-returning functions (`SETOF` and `TABLE`).
//!
//! Mirrors pgrx's `SetOfIterator` and `TableIterator`. A function returns a
//! `SetOf(I)` or `Table(I)` wrapping an iterator `I`: any struct with a
//! `next` method that yields the next row, or null when the set is exhausted.
//!
//! ```zig
//! const Count = struct {
//!     cur: i32,
//!     end: i32,
//!
//!     pub fn next(self: *Count) ?i32 {
//!         if (self.cur > self.end) return null;
//!         defer self.cur += 1;
//!         return self.cur;
//!     }
//! };
//!
//! pub fn count_to(n: i32) srf.SetOf(Count) {
//!     return .{ .iter = .{ .cur = 1, .end = n } };
//! }
//! ```
//!
//! `next` may also return an error union (`!?Item`); an error is raised as a
//! Postgres error. For `Table(I)` the item is a struct whose fields are the
//! columns, in order, and whose names become the `RETURNS TABLE` column names
//! in generated DDL. Use `SetOf(I)` for a single unnamed column and `Table(I)`
//! for several.
//!
//! This is the value-per-call protocol: Postgres calls the function once per
//! row. The function itself runs only on the first call, in a memory context
//! that lives for the whole set (`multi_call_memory_ctx`), together with its
//! argument conversions. The iterator is moved there and later calls only
//! run `next`. Allocate everything the iterator needs while building it, with
//! `mem.PGCurrentContextAllocator`: `next` runs in a short-lived per-call
//! context, so memory it allocates is only good for the row it returns.
//!
//! An iterator type may have `fn deinit(self: *I) void`. It runs when the set
//! ends or the query stops early (a `LIMIT`, an error, a cancelled query), as
//! a memory context reset callback. It must not allocate or raise errors.
//!
//! The result is converted with the datum converters, so the item types are
//! the same ones that work for ordinary function results.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const datum = @import("datum.zig");
const meta = @import("meta.zig");

/// Returns a set of single-column rows: `RETURNS SETOF <item>`.
pub fn SetOf(comptime I: type) type {
    return struct {
        iter: I,

        pub const pgzx_srf = Kind.setof;
        pub const Iter = I;
        pub const Item = IterItem(I);
        pub const sql_returns: []const u8 = "SETOF " ++ datum.sqlType(Item);
    };
}

/// Returns a set of rows with named columns: `RETURNS TABLE (...)`. The item
/// of `I` is a struct, one field per column.
pub fn Table(comptime I: type) type {
    return struct {
        iter: I,

        pub const pgzx_srf = Kind.table;
        pub const Iter = I;
        pub const Item = IterItem(I);
        pub const sql_returns: []const u8 = tableSql(Item);

        comptime {
            if (@typeInfo(Item) != .@"struct") {
                @compileError("pgzx.srf.Table: the item of '" ++ @typeName(I) ++ "' must be a struct, found '" ++ @typeName(Item) ++ "'");
            }
        }
    };
}

pub const Kind = enum { setof, table };

/// Whether `T` is a `SetOf` or `Table` wrapper.
pub fn isSetReturning(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "pgzx_srf");
}

/// Item type of an iterator: the payload of `next`'s `?Item` or `!?Item`.
pub fn IterItem(comptime I: type) type {
    if (!@hasDecl(I, "next")) {
        @compileError("pgzx.srf: iterator '" ++ @typeName(I) ++ "' needs a `next(self: *I)` method");
    }
    const R = meta.fnReturnType(@TypeOf(I.next));
    const payload = switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
    return switch (@typeInfo(payload)) {
        .optional => |o| o.child,
        else => @compileError("pgzx.srf: `" ++ @typeName(I) ++ ".next` must return `?Item` or `!?Item`"),
    };
}

/// Number of columns in a `Table` row.
pub fn columnCount(comptime Item: type) usize {
    return @typeInfo(Item).@"struct".field_names.len;
}

/// Whether `next` can fail.
pub fn nextCanFail(comptime I: type) bool {
    return @typeInfo(meta.fnReturnType(@TypeOf(I.next))) == .error_union;
}

fn tableSql(comptime Item: type) []const u8 {
    comptime {
        if (@typeInfo(Item) != .@"struct") return "TABLE()";
        const info = @typeInfo(Item).@"struct";
        var sql: []const u8 = "TABLE(";
        for (info.field_names, info.field_types, 0..) |name, T, i| {
            if (i > 0) sql = sql ++ ", ";
            sql = sql ++ name ++ " " ++ datum.sqlType(T);
        }
        return sql ++ ")";
    }
}

/// Fixtures for the in-server tests; exported by `src/testing.zig`.
pub const TestFns = struct {
    pub var deinit_count: u32 = 0;

    const Range = struct {
        cur: i32,
        end: i32,

        pub fn next(self: *Range) ?i32 {
            if (self.cur > self.end) return null;
            defer self.cur += 1;
            return self.cur;
        }

        pub fn deinit(self: *Range) void {
            _ = self;
            deinit_count += 1;
        }
    };

    pub fn series(start: i32, end: i32) SetOf(Range) {
        return .{ .iter = .{ .cur = start, .end = end } };
    }

    const Odds = struct {
        cur: i32 = 0,
        end: i32,

        pub fn next(self: *Odds) ?(?i32) {
            if (self.cur >= self.end) return null;
            defer self.cur += 1;
            const item: ?i32 = if (@mod(self.cur, 2) == 1) null else self.cur;
            return item;
        }
    };

    pub fn gaps(n: i32) SetOf(Odds) {
        return .{ .iter = .{ .end = n } };
    }

    const Words = struct {
        it: std.mem.TokenIterator(u8, .scalar),

        pub fn next(self: *Words) ?[]const u8 {
            return self.it.next();
        }
    };

    pub fn words(text: []const u8) SetOf(Words) {
        return .{ .iter = .{ .it = std.mem.tokenizeScalar(u8, text, ' ') } };
    }

    const Pair = struct { id: i32, label: [:0]const u8 };
    const Pairs = struct {
        cur: usize = 0,
        n: usize,

        const labels = [_][:0]const u8{ "alpha", "beta", "gamma", "delta" };

        pub fn next(self: *Pairs) ?Pair {
            if (self.cur >= self.n) return null;
            defer self.cur += 1;
            return .{ .id = @intCast(self.cur + 1), .label = labels[self.cur % labels.len] };
        }
    };

    pub fn pairs(n: i32) Table(Pairs) {
        return .{ .iter = .{ .n = @intCast(n) } };
    }

    const Single = struct { value: i32 };
    const Singles = struct {
        cur: i32 = 0,
        n: i32,

        pub fn next(self: *Singles) ?Single {
            if (self.cur >= self.n) return null;
            defer self.cur += 1;
            return .{ .value = self.cur * 10 };
        }
    };

    pub fn singles(n: i32) Table(Singles) {
        return .{ .iter = .{ .n = n } };
    }

    const Failing = struct {
        cur: i32 = 0,

        pub fn next(self: *Failing) !?i32 {
            if (self.cur >= 2) return error.TestIteratorFailed;
            defer self.cur += 1;
            return self.cur;
        }
    };

    pub fn failing() SetOf(Failing) {
        return .{ .iter = .{} };
    }
};

pub const TestSuite_Srf = struct {
    const testing = std.testing;
    const spi = @import("spi.zig");
    const mem = @import("mem.zig");

    const functions = [_]struct { name: []const u8, signature: []const u8, returns: []const u8 }{
        .{ .name = "pgzx_test_srf_series", .signature = "int, int", .returns = "SETOF int" },
        .{ .name = "pgzx_test_srf_gaps", .signature = "int", .returns = "SETOF int" },
        .{ .name = "pgzx_test_srf_words", .signature = "text", .returns = "SETOF text" },
        .{ .name = "pgzx_test_srf_pairs", .signature = "int", .returns = "TABLE(id int, label text)" },
        .{ .name = "pgzx_test_srf_singles", .signature = "int", .returns = "TABLE(value int)" },
        .{ .name = "pgzx_test_srf_failing", .signature = "", .returns = "SETOF int" },
    };

    /// Declare the fixture functions from the library that `run_tests` was
    /// loaded from, so they bind to the same module instance as the tests.
    fn declareFunctions() !void {
        var rows = try spi.queryTyped([:0]const u8, "SELECT probin FROM pg_proc WHERE proname = 'run_tests' LIMIT 1", .{ .read_only = true });
        defer rows.deinit();
        const library = (try rows.next()) orelse return error.TestLibraryNotFound;

        var arena = std.heap.ArenaAllocator.init(mem.PGCurrentContextAllocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const escaped = try std.mem.replaceOwned(u8, allocator, library, "'", "''");
        inline for (functions) |f| {
            const sql = try std.fmt.allocPrintSentinel(
                allocator,
                "CREATE OR REPLACE FUNCTION {s}({s}) RETURNS {s} AS '{s}', '{s}' LANGUAGE C",
                .{ f.name, f.signature, f.returns, escaped, f.name },
                0,
            );
            _ = try spi.exec(sql, .{});
        }
    }

    fn collectInts(comptime sql: [:0]const u8) !std.ArrayList(i32) {
        var out: std.ArrayList(i32) = .empty;
        errdefer out.deinit(mem.PGCurrentContextAllocator);
        var rows = try spi.queryTyped(i32, sql, .{ .read_only = true });
        defer rows.deinit();
        while (try rows.next()) |v| try out.append(mem.PGCurrentContextAllocator, v);
        return out;
    }

    pub fn testSetOfScalar() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var got = try collectInts("SELECT * FROM pgzx_test_srf_series(1, 5)");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, got.items);
    }

    pub fn testEmptySet() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var got = try collectInts("SELECT * FROM pgzx_test_srf_series(3, 2)");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqual(@as(usize, 0), got.items.len);
    }

    pub fn testSetInTargetList() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var got = try collectInts("SELECT pgzx_test_srf_series(1, 3)");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, got.items);
    }

    pub fn testPerRowArguments() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        // The function runs once per input row, each with its own set.
        var got = try collectInts("SELECT s FROM generate_series(1, 3) AS g(n), LATERAL pgzx_test_srf_series(g.n, 3) AS s");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 2, 3, 3 }, got.items);
    }

    pub fn testNullItems() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var rows = try spi.queryTyped(?i32, "SELECT * FROM pgzx_test_srf_gaps(4)", .{ .read_only = true });
        defer rows.deinit();
        try testing.expectEqual(@as(?(?i32), 0), try rows.next());
        try testing.expectEqual(@as(?(?i32), @as(?i32, null)), try rows.next());
        try testing.expectEqual(@as(?(?i32), 2), try rows.next());
        try testing.expectEqual(@as(?(?i32), @as(?i32, null)), try rows.next());
        try testing.expectEqual(@as(?(?i32), null), try rows.next());
    }

    pub fn testTextArgumentAndItems() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var rows = try spi.queryTyped([:0]const u8, "SELECT * FROM pgzx_test_srf_words('one two  three')", .{ .read_only = true });
        defer rows.deinit();
        try testing.expectEqualStrings("one", (try rows.next()).?);
        try testing.expectEqualStrings("two", (try rows.next()).?);
        try testing.expectEqualStrings("three", (try rows.next()).?);
        try testing.expect((try rows.next()) == null);
    }

    pub fn testTableRows() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        const Row = struct { id: i32, label: [:0]const u8 };
        var rows = try spi.queryTyped(Row, "SELECT id, label FROM pgzx_test_srf_pairs(3)", .{ .read_only = true });
        defer rows.deinit();

        const first = (try rows.next()).?;
        try testing.expectEqual(@as(i32, 1), first.id);
        try testing.expectEqualStrings("alpha", first.label);
        const second = (try rows.next()).?;
        try testing.expectEqual(@as(i32, 2), second.id);
        try testing.expectEqualStrings("beta", second.label);
        const third = (try rows.next()).?;
        try testing.expectEqual(@as(i32, 3), third.id);
        try testing.expectEqualStrings("gamma", third.label);
        try testing.expect((try rows.next()) == null);
    }

    pub fn testSingleColumnTable() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var got = try collectInts("SELECT value FROM pgzx_test_srf_singles(3)");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqualSlices(i32, &.{ 0, 10, 20 }, got.items);
    }

    pub fn testDeinitRunsAfterFullScan() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        const before = TestFns.deinit_count;
        var got = try collectInts("SELECT * FROM pgzx_test_srf_series(1, 3)");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqual(before + 1, TestFns.deinit_count);
    }

    /// A `LIMIT` stops the scan before the iterator is exhausted. The iterator
    /// is still cleaned up when the executor shuts the function down.
    pub fn testDeinitRunsOnEarlyStop() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        const before = TestFns.deinit_count;
        var got = try collectInts("SELECT * FROM pgzx_test_srf_series(1, 1000000) LIMIT 3");
        defer got.deinit(mem.PGCurrentContextAllocator);
        try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, got.items);
        try testing.expectEqual(before + 1, TestFns.deinit_count);
    }

    fn scanFailing() !void {
        var got = try collectInts("SELECT * FROM pgzx_test_srf_failing()");
        got.deinit(mem.PGCurrentContextAllocator);
    }

    pub fn testIteratorErrorIsPostgresError() !void {
        try spi.connect();
        defer spi.finish();
        try declareFunctions();

        var edata: ?*pg.ErrorData = null;
        try testing.expectError(error.PGErrorStack, spi.subtransaction(scanFailing, .{}, .{ .error_data = &edata }));
        const e = edata orelse return error.TestUnexpectedResult;
        defer pg.FreeErrorData(e);
        try testing.expectEqual(@as(c_int, pg.ERRCODE_INTERNAL_ERROR), e.*.sqlerrcode);
    }
};
