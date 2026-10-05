//! Transaction, full transaction and command identifiers.
//!
//! Mirrors pgrx's `pgrx::xid` module. The types are `extern struct`
//! wrappers around the raw Postgres integers (`TransactionId`,
//! `FullTransactionId`, `CommandId`) so they stay bit-compatible with C, but
//! are distinct Zig types: that lets `datum.zig` map them to the SQL `xid`,
//! `xid8` and `cid` types instead of `bigint`.
//!
//! Plain `TransactionId` values are 32-bit and wrap around, so ordering them
//! with `<` is wrong. Use `Xid.precedes` and friends, which implement the
//! circular comparison of `TransactionIdPrecedes()`.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");

/// 32-bit transaction id (`xid`), compared modulo 2^32.
pub const Xid = extern struct {
    value: pg.TransactionId,

    pub const invalid: Xid = .{ .value = 0 };
    pub const bootstrap: Xid = .{ .value = 1 };
    pub const frozen: Xid = .{ .value = 2 };
    pub const first_normal: Xid = .{ .value = 3 };

    comptime {
        std.debug.assert(invalid.value == pg.InvalidTransactionId);
        std.debug.assert(bootstrap.value == pg.BootstrapTransactionId);
        std.debug.assert(frozen.value == pg.FrozenTransactionId);
        std.debug.assert(first_normal.value == pg.FirstNormalTransactionId);
    }

    pub inline fn isValid(self: Xid) bool {
        return self.value != invalid.value;
    }

    /// Normal ids are the only ones that take part in wraparound ordering.
    /// The special ids (invalid, bootstrap, frozen) sort below all of them.
    pub inline fn isNormal(self: Xid) bool {
        return self.value >= first_normal.value;
    }

    pub inline fn eql(a: Xid, b: Xid) bool {
        return a.value == b.value;
    }

    /// Signed distance `a - b` on the xid circle.
    inline fn distance(a: Xid, b: Xid) i32 {
        return @bitCast(a.value -% b.value);
    }

    /// `TransactionIdPrecedes`: is `a` logically older than `b`?
    pub inline fn precedes(a: Xid, b: Xid) bool {
        if (!a.isNormal() or !b.isNormal()) return a.value < b.value;
        return distance(a, b) < 0;
    }

    pub inline fn precedesOrEquals(a: Xid, b: Xid) bool {
        if (!a.isNormal() or !b.isNormal()) return a.value <= b.value;
        return distance(a, b) <= 0;
    }

    /// `TransactionIdFollows`: is `a` logically newer than `b`?
    pub inline fn follows(a: Xid, b: Xid) bool {
        if (!a.isNormal() or !b.isNormal()) return a.value > b.value;
        return distance(a, b) > 0;
    }

    pub inline fn followsOrEquals(a: Xid, b: Xid) bool {
        if (!a.isNormal() or !b.isNormal()) return a.value >= b.value;
        return distance(a, b) >= 0;
    }

    /// Extend to a 64-bit `Xid8` using the server's current epoch
    /// (`xid_to_64bit` in pgrx, `XidFromFullTransactionId` inverse).
    ///
    /// The id must be at most about 2^31 transactions away from the next
    /// transaction id to be assigned, which holds for any id that can still
    /// be found in a running cluster.
    pub fn toXid8(self: Xid) Xid8 {
        const next = Xid8{ .value = pg.ReadNextFullTransactionId().value };
        return extendXid(self, next.xid(), next.epoch());
    }
};

/// 64-bit transaction id (`xid8`): the epoch in the high half and the plain
/// `Xid` in the low half. Never wraps, so plain integer comparison is correct.
pub const Xid8 = extern struct {
    value: u64,

    pub const invalid: Xid8 = .fromParts(0, .invalid);
    pub const first_normal: Xid8 = .fromParts(0, .first_normal);

    pub inline fn fromParts(epoch_: u32, xid_: Xid) Xid8 {
        return .{ .value = (@as(u64, epoch_) << 32) | xid_.value };
    }

    pub inline fn epoch(self: Xid8) u32 {
        return @truncate(self.value >> 32);
    }

    pub inline fn xid(self: Xid8) Xid {
        return .{ .value = @truncate(self.value) };
    }

    pub inline fn isValid(self: Xid8) bool {
        return self.xid().isValid();
    }

    pub inline fn eql(a: Xid8, b: Xid8) bool {
        return a.value == b.value;
    }

    pub inline fn precedes(a: Xid8, b: Xid8) bool {
        return a.value < b.value;
    }

    pub inline fn precedesOrEquals(a: Xid8, b: Xid8) bool {
        return a.value <= b.value;
    }

    pub inline fn follows(a: Xid8, b: Xid8) bool {
        return a.value > b.value;
    }

    pub inline fn followsOrEquals(a: Xid8, b: Xid8) bool {
        return a.value >= b.value;
    }

    pub inline fn fromPg(v: pg.FullTransactionId) Xid8 {
        return .{ .value = v.value };
    }

    pub inline fn toPg(self: Xid8) pg.FullTransactionId {
        return .{ .value = self.value };
    }
};

/// Command id (`cid`): the sequence number of a command within a transaction.
pub const Cid = extern struct {
    value: pg.CommandId,

    pub const first: Cid = .{ .value = 0 };
    pub const invalid: Cid = .{ .value = std.math.maxInt(pg.CommandId) };

    comptime {
        std.debug.assert(first.value == pg.FirstCommandId);
        std.debug.assert(invalid.value == pg.InvalidCommandId);
    }

    pub inline fn isValid(self: Cid) bool {
        return self.value != invalid.value;
    }
};

/// Place `xid` on the 64-bit line given the next xid to be assigned
/// (`last_xid`) and its epoch. An id numerically above `last_xid` that
/// precedes it in circular order belongs to the previous epoch, and the other
/// way around. Special ids are returned as they are.
fn extendXid(xid: Xid, last_xid: Xid, epoch: u32) Xid8 {
    if (!xid.isNormal()) return .{ .value = xid.value };

    var e: u64 = epoch;
    if (xid.value > last_xid.value and xid.precedes(last_xid)) {
        e -%= 1;
    } else if (xid.value < last_xid.value and xid.follows(last_xid)) {
        e += 1;
    }
    return .{ .value = (e << 32) | xid.value };
}

/// Id of the current (sub)transaction. Assigns one if necessary, which can
/// raise a Postgres error (for instance during recovery).
pub fn currentTransactionId() err.ElogIndicator!Xid {
    return .{ .value = try err.wrap(pg.GetCurrentTransactionId, .{}) };
}

/// Id of the current (sub)transaction, or `Xid.invalid` if none was assigned.
pub fn currentTransactionIdIfAny() Xid {
    return .{ .value = pg.GetCurrentTransactionIdIfAny() };
}

/// Id of the top-level transaction. Assigns one if necessary.
pub fn topTransactionId() err.ElogIndicator!Xid {
    return .{ .value = try err.wrap(pg.GetTopTransactionId, .{}) };
}

/// `xid8` of the current transaction. Assigns one if necessary.
pub fn currentFullTransactionId() err.ElogIndicator!Xid8 {
    return .fromPg(try err.wrap(pg.GetCurrentFullTransactionId, .{}));
}

/// Command id of the running command. With `used` the id is marked as used
/// and the next call yields a fresh one; this errors if the transaction has
/// run out of command ids.
pub fn currentCommandId(used: bool) err.ElogIndicator!Cid {
    return .{ .value = try err.wrap(pg.GetCurrentCommandId, .{used}) };
}

pub const TestSuite_Xid = struct {
    const testing = std.testing;

    fn x(v: u32) Xid {
        return .{ .value = v };
    }

    pub fn testConstants() !void {
        try testing.expect(!Xid.invalid.isValid());
        try testing.expect(Xid.bootstrap.isValid());
        try testing.expect(!Xid.frozen.isNormal());
        try testing.expect(Xid.first_normal.isNormal());
        try testing.expect(!Cid.invalid.isValid());
        try testing.expect(Cid.first.isValid());
    }

    pub fn testPlainOrdering() !void {
        try testing.expect(x(10).precedes(x(11)));
        try testing.expect(!x(11).precedes(x(10)));
        try testing.expect(!x(10).precedes(x(10)));
        try testing.expect(x(10).precedesOrEquals(x(10)));
        try testing.expect(x(11).follows(x(10)));
        try testing.expect(x(10).followsOrEquals(x(10)));
    }

    pub fn testWraparoundOrdering() !void {
        // 0xFFFFFFF0 is just before wraparound, 5 just after it: the newer id
        // is numerically smaller.
        try testing.expect(x(0xFFFFFFF0).precedes(x(5)));
        try testing.expect(x(5).follows(x(0xFFFFFFF0)));
        try testing.expect(!x(0xFFFFFFF0).follows(x(5)));
    }

    pub fn testSpecialIdsOrdering() !void {
        // Special ids compare numerically: they are older than every normal id.
        try testing.expect(Xid.frozen.precedes(x(3)));
        try testing.expect(Xid.frozen.precedes(x(0xFFFFFFF0)));
        try testing.expect(x(0xFFFFFFF0).follows(Xid.bootstrap));
    }

    pub fn testMatchesPostgres() !void {
        const samples = [_]u32{ 0, 1, 2, 3, 4, 100, 0x7FFFFFFF, 0x80000000, 0x80000003, 0xFFFFFFF0, 0xFFFFFFFF };
        for (samples) |a| {
            for (samples) |b| {
                try testing.expectEqual(pg.TransactionIdPrecedes(a, b), x(a).precedes(x(b)));
                try testing.expectEqual(pg.TransactionIdPrecedesOrEquals(a, b), x(a).precedesOrEquals(x(b)));
                try testing.expectEqual(pg.TransactionIdFollows(a, b), x(a).follows(x(b)));
                try testing.expectEqual(pg.TransactionIdFollowsOrEquals(a, b), x(a).followsOrEquals(x(b)));
            }
        }
    }

    pub fn testXid8Parts() !void {
        const full: Xid8 = .fromParts(7, x(42));
        try testing.expectEqual(@as(u32, 7), full.epoch());
        try testing.expectEqual(@as(u32, 42), full.xid().value);
        try testing.expectEqual(@as(u64, (7 << 32) | 42), full.value);
        try testing.expect(full.isValid());
        try testing.expect(!Xid8.invalid.isValid());

        const expected = pg.FullTransactionIdFromEpochAndXid(7, 42);
        try testing.expectEqual(expected.value, full.value);
        try testing.expectEqual(full.value, Xid8.fromPg(full.toPg()).value);
    }

    pub fn testXid8Ordering() !void {
        const a: Xid8 = .fromParts(0, x(0xFFFFFFF0));
        const b: Xid8 = .fromParts(1, x(5));
        try testing.expect(a.precedes(b));
        try testing.expect(b.follows(a));
        try testing.expect(a.precedesOrEquals(a));
        try testing.expect(a.followsOrEquals(a));
    }

    pub fn testExtendXid() !void {
        // Next xid is 10 in epoch 3.
        const last = x(10);

        // Special ids are returned unchanged.
        try testing.expectEqual(@as(u64, 2), extendXid(Xid.frozen, last, 3).value);

        // Plain recent id: same epoch.
        try testing.expectEqual(Xid8.fromParts(3, x(7)).value, extendXid(x(7), last, 3).value);

        // Id just before wraparound while the next id already wrapped: the
        // previous epoch.
        try testing.expectEqual(Xid8.fromParts(2, x(0xFFFFFFF0)).value, extendXid(x(0xFFFFFFF0), last, 3).value);

        // Id slightly ahead of an id that is about to wrap: the next epoch.
        const near_wrap = x(0xFFFFFFF0);
        try testing.expectEqual(Xid8.fromParts(4, x(5)).value, extendXid(x(5), near_wrap, 3).value);
    }

    pub fn testCurrentIds() !void {
        const xid8 = try currentFullTransactionId();
        try testing.expect(xid8.isValid());
        try testing.expectEqual(xid8.xid().value, (try currentTransactionId()).value);
        try testing.expectEqual(xid8.xid().value, currentTransactionIdIfAny().value);

        const cid = try currentCommandId(false);
        try testing.expect(cid.isValid());
    }

    pub fn testToXid8UsesServerEpoch() !void {
        const current = try currentTransactionId();
        const full = current.toXid8();
        try testing.expectEqual(current.value, full.xid().value);
        try testing.expectEqual((try currentFullTransactionId()).value, full.value);
    }
};
