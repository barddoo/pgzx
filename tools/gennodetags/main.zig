const std = @import("std");

const pg = @cImport({
    // Must come first: works around a translate-c hang on macOS, see
    // src/pgzx/c/include/pgzx_translate_prelude.h.
    @cInclude("pgzx_translate_prelude.h");
    @cInclude("c.h");
    @cInclude("utils/palloc.h");
    @cInclude("nodes/nodes.h");
});

const tagsOnly = std.StaticStringMap(void).initComptime([_]struct { []const u8 }{
    // Internal markers
    .{"T_Invalid"},

    // Tags for internal types
    .{"T_AllocSetContext"},
    .{"T_GenerationContext"},
    .{"T_SlabContext"},
    .{"T_WindowObjectData"},
    .{"T_BumpContext"},

    // List types (only tags, all use the `List` type)
    .{"T_IntList"},
    .{"T_OidList"},
    .{"T_XidList"},

    // PG15-only tag with no corresponding node type (removed in PG16)
    .{"T_PathKeyInfo"},
});

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2)
        fatal("wrong number of arguments", .{});

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(arena);

    try buf.appendSlice(arena,
        \\pub const std = @import("std");
        \\
        \\pub const pg = @import("pgzx_pgsys");
        \\
        \\
    );

    // 1. collect all node tags into `node_tags` list using comptime reflection.
    @setEvalBranchQuota(50000);
    var node_tags = std.ArrayList([]const u8).empty;
    defer node_tags.deinit(arena);
    const pg_mod = @typeInfo(pg).@"struct";
    inline for (pg_mod.decls) |decl| {
        const name = decl.name;
        if (std.mem.startsWith(u8, name, "T_")) {
            node_tags.append(arena, decl.name) catch |err| {
                fatal("build node tags list: {}\n", .{err});
            };
        }
    }

    // 2. Create `Tag enum` with all known node tags.
    try buf.appendSlice(arena, "pub const Tag = enum (pg.NodeTag) {\n");
    for (node_tags.items) |tag| {
        try buf.print(arena, "{s} = pg.{s},\n", .{ tag[2..], tag });
    }
    try buf.appendSlice(arena, "};\n\n");

    // 3. Create types -> tags mappings. Only add tags for valid types.
    try buf.appendSlice(arena, "pub const TypeTagTable = .{\n");
    for (node_tags.items) |tag| {
        if (tagsOnly.has(tag))
            continue;

        try buf.print(arena, ".{{pg.{s}, pg.{s}}},\n", .{ tag, tag[2..] });
    }
    try buf.appendSlice(arena, "};\n");

    try buf.appendSlice(arena,
        \\pub inline fn findTag(comptime T: type) ?Tag {
        \\    inline for (TypeTagTable) |entry| {
        \\        if (entry[1] == T) {
        \\            return @enumFromInt(entry[0]);
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\pub inline fn findType(comptime tag: Tag) ?type {
        \\    const tag_int: c_int = @intCast(@intFromEnum(tag));
        \\    inline for (TypeTagTable) |entry| {
        \\        if (entry[0] == tag_int) {
        \\            return entry[1];
        \\        }
        \\    }
        \\    return null;
        \\}
    );

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[1],
        .data = buf.items,
    });

    return std.process.cleanExit(init.io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
