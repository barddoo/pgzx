const std = @import("std");
const pg = @import("pgzx_pgsys");
const mem = @import("../mem.zig");

// Wrappers for postgres integer and OID lists (`T_IntList`, `T_OidList`).
//
// These use the same growing cell array as pointer lists, but store the value
// inline in the `ListCell` union instead of a pointer.
//
// All allocations are done one the current postgres memory context.

pub const IntList = ValueListOf(struct {
    pub const Value = c_int;
    pub const tag = pg.T_IntList;
    pub const field = "int_value";
    pub const lappend = pg.lappend_int;
    pub const lcons = pg.lcons_int;
    pub const member = pg.list_member_int;
    pub const delete = pg.list_delete_int;
    pub const append_unique = pg.list_append_unique_int;
    pub const cmp = pg.list_int_cmp;
});

pub const OidList = ValueListOf(struct {
    pub const Value = pg.Oid;
    pub const tag = pg.T_OidList;
    pub const field = "oid_value";
    pub const lappend = pg.lappend_oid;
    pub const lcons = pg.lcons_oid;
    pub const member = pg.list_member_oid;
    pub const delete = pg.list_delete_oid;
    pub const append_unique = pg.list_append_unique_oid;
    pub const cmp = pg.list_oid_cmp;
});

fn ValueListOf(comptime kind: type) type {
    return struct {
        const Self = @This();
        pub const Value = kind.Value;

        list: ?*pg.List,

        pub fn init() Self {
            return Self.initFrom(null);
        }

        pub fn initFrom(from: ?*pg.List) Self {
            if (from) |l| {
                if (l.type != kind.tag) {
                    @panic("Unexpected list type");
                }
            }
            return Self{ .list = from };
        }

        /// Builds a list holding a copy of `values`.
        pub fn initSlice(values: []const Value) Self {
            var self = Self.init();
            for (values) |v| self.append(v);
            return self;
        }

        pub fn deinit(self: Self) void {
            pg.list_free(self.list);
        }

        pub fn rawList(self: Self) ?*pg.List {
            return self.list;
        }

        pub fn copy(self: Self) Self {
            return Self.initFrom(pg.list_copy(self.list));
        }

        pub inline fn len(self: Self) usize {
            return @intCast(pg.list_length(self.list));
        }

        pub fn at(self: Self, n: usize) Value {
            const l = self.list orelse @panic("Index out of bounds");
            if (n >= self.len()) {
                @panic("Index out of bounds");
            }
            return @field(l.*.elements[n], kind.field);
        }

        pub fn append(self: *Self, value: Value) void {
            self.list = kind.lappend(self.list, value);
        }

        pub fn prepend(self: *Self, value: Value) void {
            self.list = kind.lcons(value, self.list);
        }

        /// Appends `value` unless it is already a member.
        pub fn appendUnique(self: *Self, value: Value) void {
            self.list = kind.append_unique(self.list, value);
        }

        pub fn member(self: Self, value: Value) bool {
            return kind.member(self.list, value);
        }

        /// Removes the first occurrence of `value`.
        pub fn delete(self: *Self, value: Value) void {
            self.list = kind.delete(self.list, value);
        }

        /// Sorts the list in ascending order.
        pub fn sort(self: Self) void {
            pg.list_sort(self.list, kind.cmp);
        }

        /// Copies the values into a slice allocated with `allocator`.
        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]Value {
            const out = try allocator.alloc(Value, self.len());
            var it = self.iterator();
            var i: usize = 0;
            while (it.next()) |v| : (i += 1) out[i] = v;
            return out;
        }

        pub fn iterator(self: Self) Iterator {
            return .{ .list = self.list, .idx = 0 };
        }

        pub const Iterator = struct {
            list: ?*pg.List,
            idx: usize,

            pub fn next(it: *Iterator) ?Value {
                const l = it.list orelse return null;
                if (it.idx >= @as(usize, @intCast(l.*.length))) return null;
                const v = @field(l.*.elements[it.idx], kind.field);
                it.idx += 1;
                return v;
            }
        };
    };
}

pub const TestSuite_ValueList = struct {
    pub fn testIntListAppendIterate() !void {
        var list = IntList.init();
        defer list.deinit();
        list.append(3);
        list.append(1);
        list.prepend(2);

        try std.testing.expectEqual(@as(usize, 3), list.len());
        try std.testing.expectEqual(@as(c_int, 2), list.at(0));

        var sum: c_int = 0;
        var it = list.iterator();
        while (it.next()) |v| sum += v;
        try std.testing.expectEqual(@as(c_int, 6), sum);
    }

    pub fn testIntListSortMemberDelete() !void {
        var list = IntList.initSlice(&.{ 5, 1, 4 });
        defer list.deinit();

        list.sort();
        try std.testing.expectEqual(@as(c_int, 1), list.at(0));
        try std.testing.expectEqual(@as(c_int, 5), list.at(2));

        try std.testing.expect(list.member(4));
        list.delete(4);
        try std.testing.expect(!list.member(4));

        list.appendUnique(1);
        try std.testing.expectEqual(@as(usize, 2), list.len());
    }

    pub fn testOidListToSlice() !void {
        var list = OidList.initSlice(&.{ pg.INT4OID, pg.TEXTOID });
        defer list.deinit();

        const values = try list.toSlice(mem.PGCurrentContextAllocator);
        defer mem.PGCurrentContextAllocator.free(values);
        try std.testing.expectEqualSlices(pg.Oid, &.{ pg.INT4OID, pg.TEXTOID }, values);
    }

    pub fn testEmptyList() !void {
        const list = IntList.init();
        try std.testing.expectEqual(@as(usize, 0), list.len());
        var it = list.iterator();
        try std.testing.expectEqual(@as(?c_int, null), it.next());
    }
};
