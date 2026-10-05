//! Safe wrapper around Postgres' `TupleDescData`.
//!
//! Mirrors pgrx's `PgTupleDesc`. A tuple descriptor describes the columns of
//! a row: their names, types and layout. Which cleanup a descriptor needs
//! depends on where it came from, so `TupleDesc` records that in `release`:
//!
//! - `.none`: Postgres owns it and keeps it alive at least as long as the
//!   caller needs it (a relation's `rd_att`, `SPI_tuptable->tupdesc`).
//! - `.refcount`: a reference-counted descriptor from the relcache or
//!   typcache (`lookup_rowtype_tupdesc`). `deinit` drops the reference.
//! - `.free`: a private copy in the caller's memory context. `deinit` frees it.
//!
//! Column numbers in this API are 0-based, like Postgres' `TupleDescAttr`.
//! `HeapTuple` uses 1-based attribute numbers, like `heap_getattr`.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const err = @import("err.zig");

pub const Attribute = pg.FormData_pg_attribute;

pub const AttributeSpec = struct {
    name: [:0]const u8,
    type_oid: pg.Oid,
    typmod: i32 = -1,
};

pub const TupleDesc = struct {
    ptr: pg.TupleDesc,
    release: Release,

    pub const Release = enum { none, refcount, free };

    const Self = @This();

    /// Wrap a descriptor that Postgres keeps alive. Returns null for null.
    pub fn fromPg(ptr: pg.TupleDesc) ?Self {
        if (ptr == null) return null;
        return .{ .ptr = ptr, .release = .none };
    }

    /// Wrap a reference-counted descriptor whose reference the caller owns,
    /// such as the result of `lookup_rowtype_tupdesc`. Returns null for null.
    pub fn fromPgPinned(ptr: pg.TupleDesc) ?Self {
        if (ptr == null) return null;
        return .{ .ptr = ptr, .release = .refcount };
    }

    /// Wrap a descriptor that is already a private copy, such as the result
    /// of `lookup_rowtype_tupdesc_copy`. `deinit` frees it. Returns null for null.
    pub fn fromOwnedCopy(ptr: pg.TupleDesc) ?Self {
        if (ptr == null) return null;
        return .{ .ptr = ptr, .release = .free };
    }

    /// Descriptor of the row type `typid`/`typmod`: a named composite or
    /// table row type (`typmod` -1), or a registered anonymous record type.
    /// The descriptor is shared and reference counted; `deinit` releases it.
    pub fn forRowType(typid: pg.Oid, mod: i32) err.ElogIndicator!Self {
        const ptr = try err.wrap(pg.lookup_rowtype_tupdesc, .{ typid, mod });
        return fromPgPinned(ptr).?;
    }

    /// Private copy of the descriptor of the composite type `typid`. Returns
    /// null if the type does not exist or is not a composite type.
    pub fn forCompositeType(typid: pg.Oid) err.ElogIndicator!?Self {
        if (typid == pg.InvalidOid) return null;
        if (pg.get_typtype(typid) != pg.TYPTYPE_COMPOSITE) return null;

        // A copy, so the descriptor survives later invalidation of the cache entry.
        const ptr = try err.wrap(pg.lookup_rowtype_tupdesc_copy, .{ typid, @as(i32, -1) });
        return fromOwnedCopy(ptr);
    }

    /// Build an anonymous `record` descriptor and register it so values formed
    /// with it can be turned into composite datums (`BlessTupleDesc`).
    pub fn createRecord(attrs: []const AttributeSpec) err.ElogIndicator!Self {
        const ptr = try err.wrap(pg.CreateTemplateTupleDesc, .{@as(c_int, @intCast(attrs.len))});
        var self = fromOwnedCopy(ptr).?;
        errdefer self.deinit();

        for (attrs, 1..) |spec, attno| {
            try err.wrap(pg.TupleDescInitEntry, .{
                ptr,
                @as(pg.AttrNumber, @intCast(attno)),
                spec.name.ptr,
                spec.type_oid,
                spec.typmod,
                @as(c_int, 0),
            });
        }
        _ = try err.wrap(pg.pgzx_bless_tupdesc, .{ptr});
        return self;
    }

    /// Private copy, including constraints, in the current memory context.
    pub fn copy(self: Self) err.ElogIndicator!Self {
        const ptr = try err.wrap(pg.CreateTupleDescCopyConstr, .{self.ptr});
        return fromOwnedCopy(ptr).?;
    }

    /// Give up ownership and return the raw descriptor. The caller must
    /// release or free it according to `release`.
    pub fn intoPg(self: *Self) pg.TupleDesc {
        self.release = .none;
        return self.ptr;
    }

    pub fn deinit(self: *Self) void {
        switch (self.release) {
            .none => {},
            // ReleaseTupleDesc(): only reference-counted descriptors are released.
            .refcount => if (self.ptr.*.tdrefcount >= 0) pg.DecrTupleDescRefCount(self.ptr),
            .free => pg.FreeTupleDesc(self.ptr),
        }
        self.release = .none;
    }

    /// `pg_type` OID of the row type, `RECORDOID` for anonymous records.
    pub fn typeId(self: Self) pg.Oid {
        return self.ptr.*.tdtypeid;
    }

    pub fn typmod(self: Self) i32 {
        return self.ptr.*.tdtypmod;
    }

    /// Number of columns, including dropped ones.
    pub fn len(self: Self) usize {
        return @intCast(self.ptr.*.natts);
    }

    /// Column `i` (0-based), or null if out of range.
    pub fn attr(self: Self, i: usize) ?*const Attribute {
        if (i >= self.len()) return null;
        // Before PG18 the attributes are a flexible array member, which
        // translate-c exposes as the `attrs()` accessor; the translated
        // `TupleDescAttr` helper refers to a plain `attrs` field and does not
        // compile there. PG18 moved to compact attributes plus a trailing
        // attribute array, which only `TupleDescAttr` knows how to find.
        if (comptime pg.PG_VERSION_NUM >= 180000) {
            return pg.TupleDescAttr(self.ptr, @as(c_int, @intCast(i)));
        } else {
            return &self.ptr.*.attrs()[i];
        }
    }

    /// Index (0-based) of the live column called `name`.
    pub fn indexOf(self: Self, name: []const u8) ?usize {
        for (0..self.len()) |i| {
            const a = self.attr(i).?;
            if (!a.attisdropped and std.mem.eql(u8, attrName(a), name)) return i;
        }
        return null;
    }
};

/// Column name of `a`, borrowed from the descriptor.
pub fn attrName(a: *const Attribute) []const u8 {
    return std.mem.sliceTo(&a.attname.data, 0);
}

pub const TestSuite_TupleDesc = struct {
    const testing = std.testing;
    const spi = @import("spi.zig");

    fn namespaceRowType() !pg.Oid {
        var rows = try spi.queryTyped(u32, "SELECT 'pg_namespace'::regtype::oid", .{ .read_only = true });
        defer rows.deinit();
        return (try rows.next()).?;
    }

    pub fn testForCompositeType() !void {
        try spi.connect();
        defer spi.finish();

        var desc = (try TupleDesc.forCompositeType(try namespaceRowType())).?;
        defer desc.deinit();

        try testing.expectEqual(TupleDesc.Release.free, desc.release);
        try testing.expectEqual(@as(i32, -1), desc.typmod());
        try testing.expectEqual(@as(usize, 4), desc.len());
        try testing.expectEqualStrings("oid", attrName(desc.attr(0).?));
        try testing.expectEqualStrings("nspname", attrName(desc.attr(1).?));
        try testing.expectEqualStrings("nspowner", attrName(desc.attr(2).?));
        try testing.expectEqualStrings("nspacl", attrName(desc.attr(3).?));
        try testing.expect(desc.attr(4) == null);
    }

    pub fn testNonCompositeTypeIsNull() !void {
        try testing.expect((try TupleDesc.forCompositeType(pg.INT4OID)) == null);
        try testing.expect((try TupleDesc.forCompositeType(pg.InvalidOid)) == null);
    }

    /// Reads attributes past the first column.
    pub fn testAttributeTypes() !void {
        try spi.connect();
        defer spi.finish();

        var desc = (try TupleDesc.forCompositeType(try namespaceRowType())).?;
        defer desc.deinit();

        try testing.expectEqual(@as(pg.Oid, pg.OIDOID), desc.attr(0).?.atttypid);
        try testing.expectEqual(@as(pg.Oid, pg.NAMEOID), desc.attr(1).?.atttypid);
        try testing.expectEqual(@as(pg.Oid, pg.OIDOID), desc.attr(2).?.atttypid);
        try testing.expectEqual(@as(pg.Oid, pg.ACLITEMARRAYOID), desc.attr(3).?.atttypid);
        try testing.expectEqual(@as(i16, 4), desc.attr(2).?.attlen);
        try testing.expect(desc.attr(2).?.attbyval);
    }

    pub fn testIndexOf() !void {
        try spi.connect();
        defer spi.finish();

        var desc = (try TupleDesc.forCompositeType(try namespaceRowType())).?;
        defer desc.deinit();

        try testing.expectEqual(@as(?usize, 1), desc.indexOf("nspname"));
        try testing.expectEqual(@as(?usize, 3), desc.indexOf("nspacl"));
        try testing.expectEqual(@as(?usize, null), desc.indexOf("missing"));
    }

    pub fn testCopy() !void {
        try spi.connect();
        defer spi.finish();

        var desc = (try TupleDesc.forCompositeType(try namespaceRowType())).?;
        defer desc.deinit();

        var dup = try desc.copy();
        defer dup.deinit();
        try testing.expect(dup.ptr != desc.ptr);
        try testing.expectEqual(desc.len(), dup.len());
        try testing.expectEqualStrings("nspname", attrName(dup.attr(1).?));
    }

    pub fn testForRowTypeIsPinned() !void {
        try spi.connect();
        defer spi.finish();

        var desc = try TupleDesc.forRowType(try namespaceRowType(), -1);
        const refs = desc.ptr.*.tdrefcount;
        try testing.expect(refs >= 1);
        try testing.expectEqual(TupleDesc.Release.refcount, desc.release);
        desc.deinit();
        try testing.expectEqual(refs - 1, TupleDesc.fromPg(desc.ptr).?.ptr.*.tdrefcount);
    }

    pub fn testCreateRecord() !void {
        var desc = try TupleDesc.createRecord(&.{
            .{ .name = "id", .type_oid = pg.INT4OID },
            .{ .name = "label", .type_oid = pg.TEXTOID },
        });
        defer desc.deinit();

        try testing.expectEqual(@as(pg.Oid, pg.RECORDOID), desc.typeId());
        try testing.expect(desc.typmod() >= 0);
        try testing.expectEqual(@as(usize, 2), desc.len());
        try testing.expectEqualStrings("id", attrName(desc.attr(0).?));
        try testing.expectEqualStrings("label", attrName(desc.attr(1).?));
        try testing.expectEqual(@as(pg.Oid, pg.TEXTOID), desc.attr(1).?.atttypid);
    }

    pub fn testIntoPgReleasesOwnership() !void {
        var desc = try TupleDesc.createRecord(&.{.{ .name = "x", .type_oid = pg.INT4OID }});
        const raw = desc.intoPg();
        desc.deinit(); // no-op after intoPg
        try testing.expectEqual(@as(usize, 1), @as(usize, @intCast(raw.*.natts)));
        pg.FreeTupleDesc(raw);
    }
};
