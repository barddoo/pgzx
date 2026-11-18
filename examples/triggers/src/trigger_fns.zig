// Trigger implementations.
//
// `upcase_name` fires BEFORE INSERT OR UPDATE on `products` and rewrites the
// `name` column to its upper-case form.  It demonstrates:
//
//   - Reading the incoming row with `tg.getNew()`
//   - Modifying a column with `HeapTuple.setByName`
//   - Returning the modified tuple so PostgreSQL writes it

const std = @import("std");
const pgzx = @import("pgzx");
const pg = pgzx.c;
const mem = pgzx.mem;

pub fn upcase_name(tg: pgzx.trigger.TriggerData) !pg.HeapTuple {
    var new = tg.getNew() orelse return null;

    const name = try new.getByName([:0]const u8, "name");

    // Allocate the upper-cased string in the current (per-tuple) memory context.
    const upper = try mem.PGCurrentContextAllocator.allocSentinel(u8, name.len, 0);
    for (name, 0..) |c, i| upper[i] = std.ascii.toUpper(c);

    try new.setByName("name", upper);
    return new.intoPg();
}
