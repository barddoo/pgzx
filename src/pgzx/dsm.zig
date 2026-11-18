//! Dynamic shared memory segments (storage/dsm.h).
//!
//! A segment is a block of shared memory another process can map by its
//! `Handle`. Send the handle to a background worker (for example as the
//! worker's main argument) and the worker can `attach` to the same bytes.
//!
//! A segment is released when the creating backend ends, unless it is pinned
//! with `pin`. Keep the creator attached until every other process is done.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");

pub const Segment = *pg.dsm_segment;
pub const Handle = pg.dsm_handle;

/// Creates a segment of `size` bytes. Raises a PostgreSQL error, returned as a
/// Zig error, when the segment cannot be created.
pub fn create(size: usize) !Segment {
    const seg = try err.wrap(pg.dsm_create, .{ size, 0 });
    return seg orelse err.PGError.SegmentCreateFailed;
}

/// Maps an existing segment by handle. Fails when the segment is gone.
pub fn attach(h: Handle) !Segment {
    const seg = try err.wrap(pg.dsm_attach, .{h});
    return seg orelse err.PGError.SegmentNotFound;
}

pub fn detach(seg: Segment) void {
    pg.dsm_detach(seg);
}

pub fn handle(seg: Segment) Handle {
    return pg.dsm_segment_handle(seg);
}

/// First byte of the mapped segment.
pub fn address(seg: Segment) [*]u8 {
    return @ptrCast(pg.dsm_segment_address(seg).?);
}

pub fn mapLength(seg: Segment) usize {
    return pg.dsm_segment_map_length(seg);
}

/// Keeps the segment alive until `unpin`, even after the creator detaches.
pub fn pin(seg: Segment) void {
    pg.dsm_pin_segment(seg);
}

pub fn unpin(h: Handle) void {
    pg.dsm_unpin_segment(h);
}

/// Keeps this process's mapping alive until the end of the transaction or
/// session instead of releasing it with the resource owner.
pub fn pinMapping(seg: Segment) void {
    pg.dsm_pin_mapping(seg);
}

pub const TestSuite_Dsm = struct {
    pub fn testCreateWriteRead() !void {
        const seg = try create(64);
        defer detach(seg);

        const bytes = address(seg)[0..mapLength(seg)];
        std.mem.writeInt(u64, bytes[0..8], 0xdeadbeef, .little);
        try std.testing.expectEqual(@as(u64, 0xdeadbeef), std.mem.readInt(u64, bytes[0..8], .little));
        try std.testing.expect(mapLength(seg) >= 64);
    }

    pub fn testHandleIsNonZero() !void {
        const seg = try create(32);
        defer detach(seg);
        try std.testing.expect(handle(seg) != 0);
    }
};
