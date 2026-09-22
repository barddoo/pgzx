//! Print an annotated hex dump of a compressed batch produced by
//! compression.zig. Pure Zig, no Postgres needed:
//!
//!   zig run src/dump.zig
//!
//! Handy when working on the on-disk format.

const std = @import("std");
const compression = @import("compression.zig");
const enc = @import("compression/encoding.zig");

fn readInt(comptime T: type, b: []const u8, off: usize) T {
    var tmp: [@sizeOf(T)]u8 = undefined;
    @memcpy(&tmp, b[off .. off + @sizeOf(T)]);
    return std.mem.readInt(T, &tmp, .little);
}

fn hexDump(label: []const u8, bytes: []const u8) void {
    std.debug.print("{s} ({d} bytes)\n", .{ label, bytes.len });
    var i: usize = 0;
    while (i < bytes.len) : (i += 16) {
        const end = @min(i + 16, bytes.len);
        std.debug.print("  {x:0>4}  ", .{i});
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < end) {
                std.debug.print("{x:0>2} ", .{bytes[i + j]});
            } else {
                std.debug.print("   ", .{});
            }
        }
        std.debug.print(" |", .{});
        for (bytes[i..end]) |b| {
            std.debug.print("{c}", .{if (b >= 0x20 and b < 0x7f) b else '.'});
        }
        std.debug.print("|\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Six rows, three columns:
    //   id    monotonic ints   -> delta
    //   temp  repeating floats -> gorilla/rle
    //   label low-card text    -> dictionary
    const ids = [_]i64{ 100, 101, 102, 103, 104, 105 };
    const temps = [_]f64{ 1.5, 1.5, 2.25, 2.25, 3.5, 3.5 };
    const labels = [_][]const u8{ "alpha", "alpha", "beta", "beta", "gamma", "gamma" };

    var c_id = try enc.encodeColumn(alloc, .{ .i64 = &ids });
    defer c_id.deinit(alloc);
    var c_temp = try enc.encodeColumn(alloc, .{ .f64 = &temps });
    defer c_temp.deinit(alloc);
    var c_label = try enc.encodeColumn(alloc, .{ .bytes = &labels });
    defer c_label.deinit(alloc);

    const cols = [_]compression.EncodedColumn{ c_id, c_temp, c_label };

    var nb = compression.NullBitmapBuilder.init(alloc);
    defer nb.deinit();
    for ([_]bool{ false, false, true, false, false, false }) |n| try nb.append(n);
    const nulls = [_]?[]const u8{ null, nb.view(), null };

    const blob = try compression.writeBatch(alloc, 6, &cols, &nulls);
    defer alloc.free(blob);

    std.debug.print("\n=== compressed batch: {d} bytes ===\n\n", .{blob.len});
    hexDump("blob", blob);

    // ---- header ----
    std.debug.print("\n--- header (16 bytes) ---\n", .{});
    std.debug.print("  magic      = 0x{x:0>8} ('PGB1')\n", .{readInt(u32, blob, 0)});
    std.debug.print("  version    = {d}\n", .{readInt(u16, blob, 4)});
    std.debug.print("  row_count  = {d}\n", .{readInt(u32, blob, 6)});
    std.debug.print("  col_count  = {d}\n", .{readInt(u16, blob, 10)});
    std.debug.print("  flags      = {d}\n", .{readInt(u16, blob, 12)});

    // ---- directory + payloads ----
    const view = try compression.BatchView.init(blob);
    std.debug.print("\n--- column directory + payloads ---\n", .{});
    for (0..view.col_count) |c| {
        const e = try view.entry(c);
        const payload = try view.payload(c);
        std.debug.print(
            "\ncolumn {d}: encoding={s} kind={s} oid={d} typlen={d} byval={} has_nulls={}\n",
            .{ c, @tagName(e.encoding), @tagName(e.kind), e.spec.oid, e.spec.len, e.spec.byval, e.has_nulls },
        );
        std.debug.print("  null_off={d} data_off={d} data_len={d}\n", .{ e.null_off, e.data_off, e.data_len });
        if (try view.nullBitmap(c)) |nbits| hexDump("  null bitmap", nbits);
        hexDump("  payload", payload);
    }

    std.debug.print("\n--- round trip ---\n", .{});
    for (0..view.col_count) |c| {
        var d = try view.decode(c, alloc);
        defer d.deinit(alloc);
        std.debug.print("  column {d} decoded tag: {s}\n", .{ c, @tagName(std.meta.activeTag(d)) });
    }
    std.debug.print("\n", .{});
}
