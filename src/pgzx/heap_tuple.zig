//! Safe interface to Postgres `HeapTuple` objects.
//!
//! Mirrors pgrx's `PgHeapTuple`. A `HeapTuple` pairs a `pg.HeapTuple` with the
//! `TupleDesc` that describes its columns, because a tuple cannot be read
//! without one. It is also how composite (row) values are represented.
//!
//! Where the tuple memory comes from decides what `deinit` does (`ownership`):
//!
//! - `.borrowed`: Postgres owns the tuple (a trigger tuple, an SPI row).
//!   `deinit` leaves it alone. `set` first makes a private copy.
//! - `.owned`: the tuple is a private allocation. `deinit` frees it.
//! - `.shell`: only the `HeapTupleData` struct is ours; the tuple header and
//!   data belong to the datum it was read from and are reclaimed with its
//!   memory context.
//!
//! Attribute numbers are 1-based, like `heap_getattr`.

const std = @import("std");

const pg = @import("pgzx_pgsys");

const datum = @import("datum.zig");
const err = @import("err.zig");
const mem = @import("mem.zig");
const tupdesc_mod = @import("tupdesc.zig");
const varatt = @import("varatt.zig");

pub const TupleDesc = tupdesc_mod.TupleDesc;
pub const Attribute = tupdesc_mod.Attribute;

pub const Ownership = enum { borrowed, owned, shell };

pub const HeapTuple = struct {
    tuple: pg.HeapTuple,
    tupdesc: TupleDesc,
    ownership: Ownership,

    const Self = @This();

    /// Wrap a tuple that Postgres owns. The tuple and `tupdesc` must stay
    /// valid while the result is used. The wrapper takes over `tupdesc` and
    /// releases it in `deinit`. Returns null for a null tuple.
    pub fn fromPg(tupdesc: TupleDesc, tuple: pg.HeapTuple) ?Self {
        if (tuple == null) return null;
        return .{ .tuple = tuple, .tupdesc = tupdesc, .ownership = .borrowed };
    }

    /// Form a tuple from one datum per column. `values.len` must equal the
    /// number of columns. The datums must match the column types.
    pub fn fromDatums(tupdesc: TupleDesc, values: []const pg.NullableDatum) !Self {
        const n = tupdesc.len();
        if (values.len != n) return err.PGError.IncorrectAttributeCount;

        const allocator = mem.PGCurrentContextAllocator;
        const datums = try allocator.alloc(pg.Datum, n);
        defer allocator.free(datums);
        const nulls = try allocator.alloc(bool, n);
        defer allocator.free(nulls);
        for (values, datums, nulls) |v, *d, *isnull| {
            d.* = v.value;
            isnull.* = v.isnull;
        }

        const tuple = try err.wrap(pg.heap_form_tuple, .{ tupdesc.ptr, datums.ptr, nulls.ptr });
        return .{ .tuple = tuple, .tupdesc = tupdesc, .ownership = .owned };
    }

    /// Form a tuple from Zig values, one per column, converted with the
    /// datum converters using each column's type. `values` is a tuple such as
    /// `.{ @as(i32, 1), "abc", @as(?i64, null) }`. The values must have the
    /// representation that matches the column type; this is not checked.
    pub fn fromValues(tupdesc: TupleDesc, values: anytype) !Self {
        const n = values.len;
        if (n != tupdesc.len()) return err.PGError.IncorrectAttributeCount;

        var datums: [n]pg.NullableDatum = undefined;
        inline for (0..n) |i| {
            datums[i] = try datum.toNullableDatumWithOID(values[i], tupdesc.attr(i).?.atttypid);
        }
        return fromDatums(tupdesc, &datums);
    }

    /// A new tuple of the composite type `typid` with every column null.
    pub fn newComposite(typid: pg.Oid) !Self {
        var tupdesc = (try TupleDesc.forCompositeType(typid)) orelse return err.PGError.NotACompositeType;
        errdefer tupdesc.deinit();

        const allocator = mem.PGCurrentContextAllocator;
        const nulls = try allocator.alloc(pg.NullableDatum, tupdesc.len());
        defer allocator.free(nulls);
        @memset(nulls, .{ .value = 0, .isnull = true });
        return fromDatums(tupdesc, nulls);
    }

    /// Read a composite datum (a `ROW(...)` value or a column of composite
    /// type). The datum is detoasted if needed. The tuple header and data are
    /// shared with the datum, which must outlive the result.
    pub fn fromCompositeDatum(d: pg.Datum) !Self {
        const raw: [*c]pg.struct_varlena = @ptrFromInt(d);
        const header: pg.HeapTupleHeader = @ptrCast(@alignCast(try err.wrap(pg.pg_detoast_datum, .{raw})));

        var tupdesc = try TupleDesc.forRowType(
            pg.HeapTupleHeaderGetTypeId(header),
            pg.HeapTupleHeaderGetTypMod(header),
        );
        errdefer tupdesc.deinit();

        const shell = try mem.PGCurrentContextAllocator.create(pg.HeapTupleData);
        shell.* = .{
            .t_len = @intCast(varatt.VARSIZE(header)),
            .t_data = header,
        };
        return .{ .tuple = shell, .tupdesc = tupdesc, .ownership = .shell };
    }

    /// Free what this wrapper owns and release the tuple descriptor.
    pub fn deinit(self: *Self) void {
        switch (self.ownership) {
            .borrowed => {},
            .owned => pg.heap_freetuple(self.tuple),
            .shell => pg.pfree(self.tuple),
        }
        self.tupdesc.deinit();
        self.ownership = .borrowed;
    }

    /// Give up ownership and return the raw tuple and descriptor, for
    /// handing to Postgres. The caller is responsible for them now.
    pub fn intoPg(self: *Self) pg.HeapTuple {
        self.ownership = .borrowed;
        _ = self.tupdesc.intoPg();
        return self.tuple;
    }

    /// Number of columns, including dropped ones.
    pub fn len(self: Self) usize {
        return self.tupdesc.len();
    }

    /// Column description for the 1-based attribute `attno`.
    pub fn attribute(self: Self, attno: usize) ?*const Attribute {
        if (attno < 1) return null;
        return self.tupdesc.attr(attno - 1);
    }

    /// 1-based attribute number of the live column called `name`.
    pub fn attnoOf(self: Self, name: []const u8) ?usize {
        const i = self.tupdesc.indexOf(name) orelse return null;
        return i + 1;
    }

    /// The raw datum of attribute `attno`. The datum points into the tuple
    /// for by-reference types, and may be toasted.
    pub fn getDatum(self: Self, attno: usize) err.PGError!pg.NullableDatum {
        const att = self.attribute(attno) orelse return err.PGError.NoSuchAttribute;
        _ = att;

        var isnull: bool = false;
        const d = pg.heap_getattr(self.tuple, @intCast(attno), self.tupdesc.ptr, &isnull);
        return .{ .value = if (isnull) 0 else d, .isnull = isnull };
    }

    /// Attribute `attno` converted to `T`. Use an optional `T` for columns that
    /// can be null; a null in a non-optional `T` is `error.UnexpectedNullValue`.
    pub fn get(self: Self, comptime T: type, attno: usize) !T {
        const att = self.attribute(attno) orelse return err.PGError.NoSuchAttribute;
        return datum.fromNullableDatumWithOID(T, try self.getDatum(attno), att.atttypid);
    }

    pub fn getByName(self: Self, comptime T: type, name: []const u8) !T {
        const attno = self.attnoOf(name) orelse return err.PGError.NoSuchAttribute;
        return self.get(T, attno);
    }

    /// Replace attribute `attno` with a raw datum. The datum must match the
    /// column type; this is not checked.
    ///
    /// This builds a new tuple, so it works on any ownership and leaves the
    /// result `.owned`. Tuples that Postgres owns are not modified.
    pub fn setDatum(self: *Self, attno: usize, value: pg.NullableDatum) !void {
        _ = self.attribute(attno) orelse return err.PGError.NoSuchAttribute;

        const n = self.len();
        const allocator = mem.PGCurrentContextAllocator;
        const datums = try allocator.alloc(pg.Datum, n);
        defer allocator.free(datums);
        const nulls = try allocator.alloc(bool, n);
        defer allocator.free(nulls);
        const replace = try allocator.alloc(bool, n);
        defer allocator.free(replace);

        @memset(datums, 0);
        @memset(nulls, false);
        @memset(replace, false);
        datums[attno - 1] = value.value;
        nulls[attno - 1] = value.isnull;
        replace[attno - 1] = true;

        const new = try err.wrap(pg.heap_modify_tuple, .{
            self.tuple,
            self.tupdesc.ptr,
            datums.ptr,
            nulls.ptr,
            replace.ptr,
        });

        switch (self.ownership) {
            .borrowed => {},
            .owned => pg.heap_freetuple(self.tuple),
            .shell => pg.pfree(self.tuple),
        }
        self.tuple = new;
        self.ownership = .owned;
    }

    /// Replace attribute `attno` with `value`, converted with the datum
    /// converters using the column's type. The Zig type must have the
    /// representation that matches the column type; this is not checked.
    pub fn set(self: *Self, attno: usize, value: anytype) !void {
        const att = self.attribute(attno) orelse return err.PGError.NoSuchAttribute;
        try self.setDatum(attno, try datum.toNullableDatumWithOID(value, att.atttypid));
    }

    pub fn setByName(self: *Self, name: []const u8, value: anytype) !void {
        const attno = self.attnoOf(name) orelse return err.PGError.NoSuchAttribute;
        try self.set(attno, value);
    }

    /// A private `.owned` copy of the tuple, which stays valid after the
    /// original is gone. The tuple descriptor is copied as well.
    pub fn toOwned(self: Self) !Self {
        const tuple = try err.wrap(pg.heap_copytuple, .{self.tuple});
        errdefer pg.heap_freetuple(tuple);
        return .{ .tuple = tuple, .tupdesc = try self.tupdesc.copy(), .ownership = .owned };
    }

    /// A composite datum holding a copy of the tuple, stamped with its type,
    /// for returning from a function or storing in a column. `self` is not
    /// consumed.
    pub fn toCompositeDatum(self: Self) !pg.Datum {
        return err.wrap(pg.heap_copy_tuple_as_datum, .{ self.tuple, self.tupdesc.ptr });
    }
};

/// Converter that lets functions take and return composite values as
/// `HeapTuple`. The SQL type is the generic `record`.
pub const HeapTupleConv = datum.Conv(struct {
    pub const Type = HeapTuple;
    pub const sql_name = "record";

    pub fn from(d: pg.Datum, oid: pg.Oid) !Type {
        _ = oid;
        return HeapTuple.fromCompositeDatum(d);
    }

    pub fn to(v: Type, oid: pg.Oid) !pg.Datum {
        _ = oid;
        return v.toCompositeDatum();
    }
});

pub const TestSuite_HeapTuple = struct {
    const testing = std.testing;
    const spi = @import("spi.zig");

    fn recordDesc() !TupleDesc {
        return TupleDesc.createRecord(&.{
            .{ .name = "id", .type_oid = pg.INT4OID },
            .{ .name = "label", .type_oid = pg.TEXTOID },
            .{ .name = "score", .type_oid = pg.FLOAT8OID },
        });
    }

    pub fn testFromValuesAndGet() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 7), @as([:0]const u8, "seven"), @as(f64, 7.5) });
        defer t.deinit();

        try testing.expectEqual(Ownership.owned, t.ownership);
        try testing.expectEqual(@as(usize, 3), t.len());
        try testing.expectEqual(@as(i32, 7), try t.get(i32, 1));
        try testing.expectEqualStrings("seven", try t.get([:0]const u8, 2));
        try testing.expectEqual(@as(f64, 7.5), try t.get(f64, 3));
    }

    pub fn testNulls() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(?i32, null), @as(?[:0]const u8, "x"), @as(?f64, null) });
        defer t.deinit();

        try testing.expectEqual(@as(?i32, null), try t.get(?i32, 1));
        try testing.expectEqual(@as(?f64, null), try t.get(?f64, 3));
        try testing.expectError(err.PGError.UnexpectedNullValue, t.get(i32, 1));
        try testing.expect((try t.getDatum(1)).isnull);
        try testing.expect(!(try t.getDatum(2)).isnull);
    }

    pub fn testAttributeAccessErrors() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 1), @as([:0]const u8, "a"), @as(f64, 1) });
        defer t.deinit();

        try testing.expectError(err.PGError.NoSuchAttribute, t.get(i32, 0));
        try testing.expectError(err.PGError.NoSuchAttribute, t.get(i32, 4));
        try testing.expectError(err.PGError.NoSuchAttribute, t.getByName(i32, "missing"));
        try testing.expect(t.attribute(0) == null);
        try testing.expect(t.attribute(4) == null);
    }

    pub fn testGetByName() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 3), @as([:0]const u8, "three"), @as(f64, 3.25) });
        defer t.deinit();

        try testing.expectEqual(@as(?usize, 2), t.attnoOf("label"));
        try testing.expectEqual(@as(i32, 3), try t.getByName(i32, "id"));
        try testing.expectEqualStrings("three", try t.getByName([:0]const u8, "label"));
        try testing.expectEqual(@as(f64, 3.25), try t.getByName(f64, "score"));
    }

    pub fn testIncorrectAttributeCount() !void {
        var desc = try recordDesc();
        defer desc.deinit();
        try testing.expectError(err.PGError.IncorrectAttributeCount, HeapTuple.fromDatums(desc, &.{}));
        try testing.expectError(err.PGError.IncorrectAttributeCount, HeapTuple.fromValues(desc, .{@as(i32, 1)}));
    }

    pub fn testSet() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 1), @as([:0]const u8, "old"), @as(f64, 1) });
        defer t.deinit();

        try t.set(1, @as(i32, 99));
        try t.setByName("label", @as([:0]const u8, "new"));
        try t.setByName("score", @as(?f64, null));

        try testing.expectEqual(@as(i32, 99), try t.get(i32, 1));
        try testing.expectEqualStrings("new", try t.get([:0]const u8, 2));
        try testing.expectEqual(@as(?f64, null), try t.get(?f64, 3));
        try testing.expectError(err.PGError.NoSuchAttribute, t.set(9, @as(i32, 1)));
    }

    pub fn testCompositeDatumRoundTrip() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 42), @as([:0]const u8, "answer"), @as(f64, 4.5) });
        defer t.deinit();

        const d = try t.toCompositeDatum();
        var back = try HeapTuple.fromCompositeDatum(d);
        defer back.deinit();

        try testing.expectEqual(Ownership.shell, back.ownership);
        try testing.expectEqual(@as(pg.Oid, pg.RECORDOID), back.tupdesc.typeId());
        try testing.expectEqual(@as(i32, 42), try back.get(i32, 1));
        try testing.expectEqualStrings("answer", try back.getByName([:0]const u8, "label"));
        try testing.expectEqual(@as(f64, 4.5), try back.getByName(f64, "score"));
    }

    pub fn testToOwnedSurvivesOriginal() !void {
        var back: HeapTuple = undefined;
        {
            var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 5), @as([:0]const u8, "five"), @as(f64, 5) });
            defer t.deinit();
            const d = try t.toCompositeDatum();
            var shell = try HeapTuple.fromCompositeDatum(d);
            defer shell.deinit();
            back = try shell.toOwned();
        }
        defer back.deinit();

        try testing.expectEqual(Ownership.owned, back.ownership);
        try testing.expectEqual(@as(i32, 5), try back.get(i32, 1));
        try testing.expectEqualStrings("five", try back.get([:0]const u8, 2));
    }

    pub fn testNewCompositeIsAllNull() !void {
        try spi.connect();
        defer spi.finish();

        var rows = try spi.queryTyped(u32, "SELECT 'pg_namespace'::regtype::oid", .{ .read_only = true });
        defer rows.deinit();
        const typid = (try rows.next()).?;

        var t = try HeapTuple.newComposite(typid);
        defer t.deinit();
        try testing.expectEqual(@as(usize, 4), t.len());
        for (1..5) |attno| try testing.expect((try t.getDatum(attno)).isnull);

        try testing.expectError(err.PGError.NotACompositeType, HeapTuple.newComposite(pg.INT4OID));
    }

    /// Reads rows produced by the server: columns after the first, mixed
    /// by-value and by-reference types, and nulls.
    pub fn testSpiRowAsHeapTuple() !void {
        try spi.connect();
        defer spi.finish();

        var rows = try spi.query(
            "SELECT 1::int4 AS a, 'two'::text AS b, 3.5::float8 AS c, NULL::int8 AS d, true AS e",
            .{ .read_only = true },
        );
        defer rows.deinit();
        try testing.expect(rows.next());

        const t = try rows.heapTuple();
        try testing.expectEqual(Ownership.borrowed, t.ownership);
        try testing.expectEqual(@as(usize, 5), t.len());
        try testing.expectEqual(@as(i32, 1), try t.getByName(i32, "a"));
        try testing.expectEqualStrings("two", try t.getByName([:0]const u8, "b"));
        try testing.expectEqual(@as(f64, 3.5), try t.getByName(f64, "c"));
        try testing.expectEqual(@as(?i64, null), try t.getByName(?i64, "d"));
        try testing.expectEqual(true, try t.getByName(bool, "e"));
    }

    /// A composite value from the server converts through the datum framework.
    pub fn testCompositeFromServer() !void {
        try spi.connect();
        defer spi.finish();

        var rows = try spi.queryTyped(HeapTuple, "SELECT ROW(10::int4, 'ten'::text, 10.5::float8)", .{ .read_only = true });
        defer rows.deinit();
        var t = (try rows.next()).?;
        defer t.deinit();

        try testing.expectEqual(@as(usize, 3), t.len());
        try testing.expectEqual(@as(i32, 10), try t.get(i32, 1));
        try testing.expectEqualStrings("ten", try t.get([:0]const u8, 2));
        try testing.expectEqual(@as(f64, 10.5), try t.get(f64, 3));
    }

    /// A tuple formed in Zig is accepted by the server as a composite value.
    pub fn testCompositeToServer() !void {
        try spi.connect();
        defer spi.finish();

        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 8), @as([:0]const u8, "eight"), @as(f64, 8.5) });
        defer t.deinit();

        var rows = try spi.queryTyped([:0]const u8, "SELECT row_to_json($1)::text", .{
            .read_only = true,
            .args = .{
                .types = &.{pg.RECORDOID},
                .values = &.{try datum.toNullableDatum(t)},
            },
        });
        defer rows.deinit();
        try testing.expectEqualStrings("{\"id\":8,\"label\":\"eight\",\"score\":8.5}", (try rows.next()).?);
    }

    pub fn testIntoPg() !void {
        var t = try HeapTuple.fromValues(try recordDesc(), .{ @as(i32, 1), @as([:0]const u8, "x"), @as(f64, 1) });
        const desc = t.tupdesc.ptr;
        const raw = t.intoPg();
        t.deinit(); // no-op after intoPg
        try testing.expect(raw != null);
        pg.heap_freetuple(raw);
        pg.FreeTupleDesc(desc);
    }
};
