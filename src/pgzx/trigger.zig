//! Trigger support.
//!
//! Wraps `TriggerData` for BEFORE/AFTER/INSTEAD OF row and statement triggers.
//!
//! Register a trigger function with `PG_TRIGGER_V1` (from `fmgr.zig`) instead
//! of `PG_FUNCTION_V1`. The callback signature is:
//!
//! ```zig
//! fn myTrigger(tg: trigger.TriggerData) !pg.HeapTuple { ... }
//! ```
//!
//! For BEFORE ROW triggers, return the tuple you want written (usually
//! `tg.getNew()` possibly modified) or a null `pg.HeapTuple` to suppress the
//! operation. AFTER and statement-level trigger return values are ignored.
//!
//! TriggerEvent bitmask constants mirror `commands/trigger.h`. The header uses
//! C preprocessor macros which translate-c cannot translate, so they are
//! re-implemented here as Zig constants and inline functions.
//!
//! Timing bits (mask 0x18):
//!   - 0x00  AFTER
//!   - 0x08  BEFORE
//!   - 0x10  INSTEAD OF
//!
//! Operation bits (mask 0x03):
//!   - 0x00  INSERT
//!   - 0x01  DELETE
//!   - 0x02  UPDATE
//!   - 0x03  TRUNCATE
//!
//! Row/Statement bit (mask 0x04):
//!   - 0x00  STATEMENT
//!   - 0x04  ROW

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");
const heap_tuple = @import("heap_tuple.zig");
const node = @import("node.zig");
const tupdesc = @import("tupdesc.zig");

// ---------------------------------------------------------------------------
// TriggerEvent constants
// ---------------------------------------------------------------------------

pub const event_opmask: u32 = 0x03;
pub const event_row: u32 = 0x04;
pub const event_timing_mask: u32 = 0x18;
pub const event_before: u32 = 0x08;
pub const event_after: u32 = 0x00;
pub const event_instead: u32 = 0x10;

pub const event_insert: u32 = 0x00;
pub const event_delete: u32 = 0x01;
pub const event_update: u32 = 0x02;
pub const event_truncate: u32 = 0x03;

// ---------------------------------------------------------------------------
// Timing / Operation / Level enums
// ---------------------------------------------------------------------------

pub const Timing = enum { before, after, instead_of };
pub const Operation = enum { insert, update, delete, truncate };
pub const Level = enum { row, statement };

pub fn timingOf(tg_event: u32) Timing {
    const bits = tg_event & event_timing_mask;
    if (bits == event_before) return .before;
    if (bits == event_instead) return .instead_of;
    return .after;
}

pub fn operationOf(tg_event: u32) Operation {
    return switch (tg_event & event_opmask) {
        event_insert => .insert,
        event_delete => .delete,
        event_update => .update,
        event_truncate => .truncate,
        else => unreachable,
    };
}

pub fn levelOf(tg_event: u32) Level {
    return if ((tg_event & event_row) != 0) .row else .statement;
}

// ---------------------------------------------------------------------------
// TriggerData wrapper
// ---------------------------------------------------------------------------

/// Ergonomic wrapper around `*pg.TriggerData`.
///
/// Obtained from `TriggerData.fromFcinfo(fcinfo)` inside a trigger function
/// registered with `PG_TRIGGER_V1`.
pub const TriggerData = struct {
    td: *pg.TriggerData,

    const Self = @This();

    /// Build a TriggerData from an `fcinfo`. Returns `NotCalledAsTrigger` if
    /// the context is not a TriggerData node.
    pub fn fromFcinfo(fcinfo: pg.FunctionCallInfo) !Self {
        const ctx = fcinfo.*.context orelse return err.PGError.NotCalledAsTrigger;
        if (!node.isA(ctx, .TriggerData)) return err.PGError.NotCalledAsTrigger;
        return .{ .td = @ptrCast(@alignCast(ctx)) };
    }

    /// Raw `TriggerEvent` bitmask — test with the `event_*` constants above or
    /// use the helper methods below.
    pub fn getEvent(self: Self) u32 {
        return @intCast(self.td.*.tg_event);
    }

    pub fn getTiming(self: Self) Timing {
        return timingOf(self.getEvent());
    }

    pub fn getOperation(self: Self) Operation {
        return operationOf(self.getEvent());
    }

    pub fn getLevel(self: Self) Level {
        return levelOf(self.getEvent());
    }

    pub fn getRelation(self: Self) pg.Relation {
        return self.td.*.tg_relation;
    }

    pub fn getTupleDesc(self: Self) tupdesc.TupleDesc {
        return tupdesc.TupleDesc.fromPg(self.td.*.tg_relation.*.rd_att).?;
    }

    pub fn getTriggerName(self: Self) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.td.*.tg_trigger.*.tgname)));
    }

    /// The OLD row for UPDATE and DELETE. NULL for INSERT and TRUNCATE.
    ///
    /// Technically this is `tg_trigtuple` for UPDATE/DELETE. The tuple is
    /// borrowed — Postgres owns it.
    pub fn getOld(self: Self) ?heap_tuple.HeapTuple {
        const op = self.getOperation();
        if (op == .insert or op == .truncate) return null;
        return heap_tuple.HeapTuple.fromPg(self.getTupleDesc(), self.td.*.tg_trigtuple);
    }

    /// The NEW row for INSERT and UPDATE. NULL for DELETE and TRUNCATE.
    ///
    /// For INSERT this is `tg_trigtuple`; for UPDATE it is `tg_newtuple`.
    /// The tuple is borrowed — Postgres owns it.
    pub fn getNew(self: Self) ?heap_tuple.HeapTuple {
        const op = self.getOperation();
        switch (op) {
            .insert => return heap_tuple.HeapTuple.fromPg(self.getTupleDesc(), self.td.*.tg_trigtuple),
            .update => return heap_tuple.HeapTuple.fromPg(self.getTupleDesc(), self.td.*.tg_newtuple),
            .delete, .truncate => return null,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const TestSuite_Trigger = struct {
    pub fn testTimingOf() !void {
        try std.testing.expectEqual(Timing.after, timingOf(event_insert | event_after));
        try std.testing.expectEqual(Timing.before, timingOf(event_insert | event_before));
        try std.testing.expectEqual(Timing.instead_of, timingOf(event_insert | event_instead));
    }

    pub fn testOperationOf() !void {
        try std.testing.expectEqual(Operation.insert, operationOf(event_insert | event_before));
        try std.testing.expectEqual(Operation.update, operationOf(event_update | event_before));
        try std.testing.expectEqual(Operation.delete, operationOf(event_delete | event_after));
        try std.testing.expectEqual(Operation.truncate, operationOf(event_truncate | event_after));
    }

    pub fn testLevelOf() !void {
        try std.testing.expectEqual(Level.row, levelOf(event_insert | event_row));
        try std.testing.expectEqual(Level.statement, levelOf(event_insert));
    }
};
