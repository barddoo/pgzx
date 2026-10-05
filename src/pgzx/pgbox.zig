//! Owning and borrowing pointers to Postgres allocated values.
//!
//! Mirrors pgrx's `PgBox`. A `PgBox(T)` is a pointer plus a flag that says who
//! frees it:
//!
//! - *owned* boxes `pfree` their value in `deinit`. Use them for values this
//!   code allocates and does not hand to Postgres, or for values Postgres
//!   returns and documents as the caller's to free.
//! - *borrowed* boxes never free. Use them for values that live as long as a
//!   Postgres memory context, for example a `fcinfo` argument or a `palloc`ed
//!   state that a memory context reset will reclaim.
//!
//! `intoPg` and `intoDatum` give up ownership, for values that are handed to
//! Postgres (a return value, an aggregate transition state, a shared context).
//!
//! Freeing goes through `pfree`, which finds the owning memory context from
//! the chunk header. An owned box must therefore not outlive a reset or
//! deletion of the context that holds its value: that value is already gone
//! and `deinit` would free it a second time.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const mem = @import("mem.zig");

pub fn PgBox(comptime T: type) type {
    return struct {
        ptr: *T,
        owned: bool,

        const Self = @This();

        /// Allocate `value` in the current memory context.
        pub fn create(value: T) error{OutOfMemory}!Self {
            return createIn(mem.PGCurrentContextAllocator, value);
        }

        /// Allocate `value` in the current memory context, zero-initialized.
        pub fn createZeroed() error{OutOfMemory}!Self {
            return create(std.mem.zeroes(T));
        }

        /// Allocate `value` with `allocator`, which must be backed by `palloc`
        /// (`mem.PGCurrentContextAllocator` or the allocator of a
        /// `mem.MemoryContextAllocator`), because `deinit` calls `pfree`.
        pub fn createIn(allocator: std.mem.Allocator, value: T) error{OutOfMemory}!Self {
            const ptr = try allocator.create(T);
            ptr.* = value;
            return .{ .ptr = ptr, .owned = true };
        }

        /// Borrow a value that Postgres owns. Returns null for a null pointer,
        /// which is the common way for Postgres to say "no value".
        pub fn fromPg(ptr: ?*T) ?Self {
            return .{ .ptr = ptr orelse return null, .owned = false };
        }

        /// Take ownership of a `palloc`ed value. Returns null for a null pointer.
        pub fn fromOwnedPg(ptr: ?*T) ?Self {
            return .{ .ptr = ptr orelse return null, .owned = true };
        }

        pub fn isOwned(self: Self) bool {
            return self.owned;
        }

        /// Release ownership and return the raw pointer, for handing the value
        /// to Postgres. The caller (or Postgres) is now responsible for it.
        pub fn intoPg(self: *Self) *T {
            self.owned = false;
            return self.ptr;
        }

        /// Release ownership and return the pointer as a `Datum`.
        pub fn intoDatum(self: *Self) pg.Datum {
            return @intFromPtr(self.intoPg());
        }

        /// Free the value if the box owns it. Borrowed boxes are left alone.
        /// Calling `deinit` again is a no-op.
        pub fn deinit(self: *Self) void {
            if (self.owned) {
                pg.pfree(self.ptr);
                self.owned = false;
            }
        }
    };
}

pub const TestSuite_PgBox = struct {
    const testing = std.testing;

    const State = struct {
        count: u64,
        flag: bool,
    };

    pub fn testCreateAndDeinit() !void {
        var box = try PgBox(State).create(.{ .count = 5, .flag = true });
        defer box.deinit();

        try testing.expect(box.isOwned());
        try testing.expectEqual(@as(u64, 5), box.ptr.count);
        box.ptr.count += 1;
        try testing.expectEqual(@as(u64, 6), box.ptr.count);
    }

    pub fn testCreateZeroed() !void {
        var box = try PgBox(State).createZeroed();
        defer box.deinit();

        try testing.expectEqual(@as(u64, 0), box.ptr.count);
        try testing.expectEqual(false, box.ptr.flag);
    }

    pub fn testDeinitReleasesMemory() !void {
        var ctx = try mem.createAllocSetContext("testPgBoxFree", .{});
        defer ctx.deinit();
        const initial = ctx.stats().freespace;

        var box = try PgBox([256]u8).createIn(ctx.allocator(), @splat(1));
        try testing.expect(ctx.stats().freespace < initial);

        box.deinit();
        try testing.expectEqual(initial, ctx.stats().freespace);
        try testing.expect(!box.isOwned());

        box.deinit(); // idempotent
    }

    pub fn testBorrowedDoesNotFree() !void {
        var ctx = try mem.createAllocSetContext("testPgBoxBorrow", .{});
        defer ctx.deinit();

        const raw = try ctx.allocator().create(State);
        raw.* = .{ .count = 9, .flag = false };
        const after_alloc = ctx.stats().freespace;

        var box = PgBox(State).fromPg(raw).?;
        try testing.expect(!box.isOwned());
        box.deinit();

        try testing.expectEqual(after_alloc, ctx.stats().freespace);
        try testing.expectEqual(@as(u64, 9), raw.count);
    }

    pub fn testFromOwnedPgFrees() !void {
        var ctx = try mem.createAllocSetContext("testPgBoxOwned", .{});
        defer ctx.deinit();
        const initial = ctx.stats().freespace;

        const raw = try ctx.allocator().create(State);
        raw.* = .{ .count = 1, .flag = true };
        try testing.expect(ctx.stats().freespace < initial);

        var box = PgBox(State).fromOwnedPg(raw).?;
        try testing.expect(box.isOwned());
        box.deinit();
        try testing.expectEqual(initial, ctx.stats().freespace);
    }

    pub fn testNullPointers() !void {
        try testing.expectEqual(@as(?PgBox(State), null), PgBox(State).fromPg(null));
        try testing.expectEqual(@as(?PgBox(State), null), PgBox(State).fromOwnedPg(null));
    }

    pub fn testIntoPgTransfersOwnership() !void {
        var ctx = try mem.createAllocSetContext("testPgBoxInto", .{});
        defer ctx.deinit();

        var box = try PgBox(State).createIn(ctx.allocator(), .{ .count = 3, .flag = true });
        const after_alloc = ctx.stats().freespace;

        const raw = box.intoPg();
        try testing.expect(!box.isOwned());
        box.deinit();

        // The value survived `deinit` and is still ours to free.
        try testing.expectEqual(after_alloc, ctx.stats().freespace);
        try testing.expectEqual(@as(u64, 3), raw.count);
        pg.pfree(raw);
    }

    pub fn testIntoDatum() !void {
        var box = try PgBox(State).create(.{ .count = 11, .flag = false });
        const d = box.intoDatum();
        try testing.expect(!box.isOwned());

        const raw: *State = @ptrFromInt(d);
        try testing.expectEqual(@as(u64, 11), raw.count);
        pg.pfree(raw);
    }
};
