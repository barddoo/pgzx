//! Helpers for working with PostgreSQL's `ItemPointerData` (`tid`) type.
//!
//! This mirrors the helpers provided by pgrx's `pgrx::itemptr` module: the
//! value type stays the raw `pg.ItemPointerData` (bit-compatible with the C
//! struct) and these functions are the ergonomic layer on top of it.
//!
//! The `tid` datum is passed by reference (`typbyval = false`), so a datum
//! holds a pointer to a 6-byte `ItemPointerData`. `datum.Tid` (in `datum.zig`)
//! wires these helpers into the datum conversion framework so `tid` can be
//! used as a function argument/return type.

const std = @import("std");

const pg = @import("pgzx_pgsys");
const mem = @import("mem.zig");

/// Reassemble the 32-bit block number from the 16-bit `bi_hi`/`bi_lo` halves.
/// Does not validate the pointer.
pub inline fn itemPointerGetBlockNumberNoCheck(ctid: pg.ItemPointerData) pg.BlockNumber {
    return (@as(u32, ctid.ip_blkid.bi_hi) << 16) | @as(u32, ctid.ip_blkid.bi_lo);
}

/// Return the offset number (tuple index within the block). Does not validate
/// the pointer.
pub inline fn itemPointerGetOffsetNumberNoCheck(ctid: pg.ItemPointerData) pg.OffsetNumber {
    return ctid.ip_posid;
}

/// Return both the block number and the offset number as a tuple.
pub inline fn itemPointerGetBoth(ctid: pg.ItemPointerData) struct { pg.BlockNumber, pg.OffsetNumber } {
    return .{
        itemPointerGetBlockNumberNoCheck(ctid),
        itemPointerGetOffsetNumberNoCheck(ctid),
    };
}

/// Split `blockno` into the `bi_hi`/`bi_lo` halves and store it together with
/// `offno` in `tid`.
pub inline fn itemPointerSetAll(tid: *pg.ItemPointerData, blockno: pg.BlockNumber, offno: pg.OffsetNumber) void {
    tid.ip_posid = offno;
    tid.ip_blkid.bi_hi = @intCast(blockno >> 16);
    tid.ip_blkid.bi_lo = @intCast(blockno & 0xffff);
}

/// A `tid` is valid when its offset number is not `InvalidOffsetNumber` (zero).
pub inline fn itemPointerIsValid(ctid: pg.ItemPointer) bool {
    if (ctid == null) return false;
    return ctid.*.ip_posid != pg.InvalidOffsetNumber;
}

/// Validating variant of `itemPointerGetBlockNumberNoCheck`.
pub inline fn itemPointerGetBlockNumber(ctid: pg.ItemPointer) pg.BlockNumber {
    std.debug.assert(itemPointerIsValid(ctid));
    return itemPointerGetBlockNumberNoCheck(ctid.*);
}

/// Validating variant of `itemPointerGetOffsetNumberNoCheck`.
pub inline fn itemPointerGetOffsetNumber(ctid: pg.ItemPointer) pg.OffsetNumber {
    std.debug.assert(itemPointerIsValid(ctid));
    return itemPointerGetOffsetNumberNoCheck(ctid.*);
}

/// Allocate a new `ItemPointerData` in the current memory context and populate
/// it. The returned pointer is owned by Postgres, not by the caller.
pub fn newItemPointer(blockno: pg.BlockNumber, offno: pg.OffsetNumber) !*pg.ItemPointerData {
    const tid = try mem.PGCurrentContextAllocator.create(pg.ItemPointerData);
    itemPointerSetAll(tid, blockno, offno);
    return tid;
}

/// Pack a `tid` into a `u64` (`block << 32 | offset`). Useful as a map key.
pub inline fn itemPointerToU64(ctid: pg.ItemPointerData) u64 {
    return (@as(u64, itemPointerGetBlockNumberNoCheck(ctid)) << 32) |
        @as(u64, itemPointerGetOffsetNumberNoCheck(ctid));
}

/// Unpack a `u64` previously produced by `itemPointerToU64`.
pub inline fn u64ToItemPointer(value: u64) pg.ItemPointerData {
    var tid: pg.ItemPointerData = .{};
    itemPointerSetAll(&tid, @intCast(value >> 32), @intCast(value & 0xffff));
    return tid;
}

/// Unpack a `u64` into its block and offset parts without building a `tid`.
pub inline fn u64ToItemPointerParts(value: u64) struct { pg.BlockNumber, pg.OffsetNumber } {
    return .{ @intCast(value >> 32), @intCast(value & 0xffff) };
}

pub const TestSuite_Itemptr = struct {
    const testing = std.testing;

    pub fn testSetAndGet() !void {
        var tid: pg.ItemPointerData = .{};
        itemPointerSetAll(&tid, 0x12345678, 7);

        try testing.expectEqual(@as(pg.BlockNumber, 0x12345678), itemPointerGetBlockNumberNoCheck(tid));
        try testing.expectEqual(@as(pg.OffsetNumber, 7), itemPointerGetOffsetNumberNoCheck(tid));

        const both = itemPointerGetBoth(tid);
        try testing.expectEqual(@as(pg.BlockNumber, 0x12345678), both[0]);
        try testing.expectEqual(@as(pg.OffsetNumber, 7), both[1]);
    }

    pub fn testIsValid() !void {
        var tid: pg.ItemPointerData = .{};
        try testing.expect(!itemPointerIsValid(&tid));

        itemPointerSetAll(&tid, 1, 1);
        try testing.expect(itemPointerIsValid(&tid));
    }

    pub fn testU64RoundTrip() !void {
        var tid: pg.ItemPointerData = .{};
        itemPointerSetAll(&tid, 0xdeadbeef, 0xbeef);

        const back = u64ToItemPointer(itemPointerToU64(tid));
        try testing.expectEqual(@as(pg.BlockNumber, 0xdeadbeef), itemPointerGetBlockNumberNoCheck(back));
        try testing.expectEqual(@as(pg.OffsetNumber, 0xbeef), itemPointerGetOffsetNumberNoCheck(back));
    }
};
