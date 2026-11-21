//! Dynamic shared areas (utils/dsa.h): a heap of allocations inside a
//! dynamic shared memory segment.
//!
//! Allocations are addressed by a `Pointer` that is valid in every process
//! attached to the area, unlike a raw address. Share the area with another
//! process by passing its `Handle` and calling `attach` there.
//!
//! Every area needs an LWLock tranche. Create one with `newTranche` and pass
//! its id to `create`.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");

pub const Area = *pg.dsa_area;
pub const Handle = pg.dsa_handle;
pub const Pointer = pg.dsa_pointer;

/// Registers a new LWLock tranche named `name` and returns its id. The name
/// is reported in wait events. Tranches are per-process here: register the id
/// in every process that uses the area.
pub fn newTranche(comptime name: [:0]const u8) c_int {
    // PostgreSQL 19 takes the tranche name in LWLockNewTrancheId and dropped
    // LWLockRegisterTranche.
    if (comptime pg.PG_VERSION_NUM >= 190000) {
        return pg.LWLockNewTrancheId(name.ptr);
    } else {
        const id = pg.LWLockNewTrancheId();
        pg.LWLockRegisterTranche(id, name.ptr);
        return id;
    }
}

/// Creates a new area in a fresh dynamic shared memory segment.
pub fn create(tranche_id: c_int) !Area {
    const area = try err.wrap(pg.dsa_create, .{tranche_id});
    return area orelse err.PGError.AreaCreateFailed;
}

/// Attaches to an area created by another process.
pub fn attach(h: Handle) !Area {
    const area = try err.wrap(pg.dsa_attach, .{h});
    return area orelse err.PGError.AreaAttachFailed;
}

pub fn detach(area: Area) void {
    pg.dsa_detach(area);
}

pub fn handle(area: Area) Handle {
    return pg.dsa_get_handle(area);
}

/// Keeps the area's segment alive until `unpin`, even after every process
/// detaches.
pub fn pin(area: Area) void {
    pg.dsa_pin(area);
}

pub fn unpin(area: Area) void {
    pg.dsa_unpin(area);
}

/// Allocates `size` bytes. Raises a PostgreSQL error, returned as a Zig error,
/// when the area cannot grow.
pub fn allocate(area: Area, size: usize) !Pointer {
    return err.wrap(pg.dsa_allocate_extended, .{ area, size, 0 });
}

pub fn free(area: Area, p: Pointer) void {
    pg.dsa_free(area, p);
}

/// Address of `p` in this process. Valid until the area is detached.
pub fn address(comptime T: type, area: Area, p: Pointer) *T {
    return @ptrCast(@alignCast(pg.dsa_get_address(area, p).?));
}

pub const TestSuite_Dsa = struct {
    pub fn testAllocateWriteRead() !void {
        const tranche = newTranche("pgzx_dsa_test");
        const area = try create(tranche);
        defer detach(area);

        const p = try allocate(area, @sizeOf(u64));
        defer free(area, p);

        const slot = address(u64, area, p);
        slot.* = 0x1234;
        try std.testing.expectEqual(@as(u64, 0x1234), address(u64, area, p).*);
    }

    pub fn testHandleIsNonZero() !void {
        const area = try create(newTranche("pgzx_dsa_test_handle"));
        defer detach(area);
        try std.testing.expect(handle(area) != 0);
    }
};
