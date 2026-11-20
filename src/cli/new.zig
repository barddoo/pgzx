//! `pgzx new` and `pgzx fingerprint`, plus the template copy/fingerprint
//! helpers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const context = @import("context.zig");
const Ctx = context.Ctx;
const cwd = context.cwd;
const exists = context.exists;
const fail = context.fail;
const pathJoin = context.pathJoin;
const projectRoot = context.projectRoot;
const readFile = context.readFile;
const templatesDir = context.templatesDir;
const trim = context.trim;
const version = context.version;
const usage = context.usage;
const warn = context.warn;
const writeFile = context.writeFile;

const NewOptions = struct {
    name: []const u8,
    dest: []const u8,
    template: []const u8,
    ref: ?[]const u8 = null,
    no_fetch: bool = false,
};

fn parseNewArgs(ctx: *Ctx, args: []const [:0]const u8) !NewOptions {
    const default_template = ctx.get("PGZX_DEFAULT_TEMPLATE") orelse "default";
    var opts: NewOptions = .{
        .name = "",
        .dest = "",
        .template = default_template,
    };

    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "--pgzx-ref")) {
            i += 1;
            if (i >= args.len) return fail("{s} needs a value", .{arg});
            if (std.mem.eql(u8, arg, "--template")) opts.template = args[i] else opts.ref = args[i];
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            opts.template = arg["--template=".len..];
        } else if (std.mem.startsWith(u8, arg, "--pgzx-ref=")) {
            opts.ref = arg["--pgzx-ref=".len..];
        } else if (std.mem.eql(u8, arg, "--no-fetch")) {
            opts.no_fetch = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try usage(ctx);
            return error.Help;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fail("unknown option '{s}'", .{arg});
        } else {
            try positional.append(ctx.arena, arg);
        }
    }
    if (positional.items.len == 0 or positional.items.len > 2) {
        try usage(ctx);
        return error.UserError;
    }
    opts.name = positional.items[0];
    opts.dest = if (positional.items.len > 1) positional.items[1] else opts.name;
    return opts;
}

pub fn cmdNew(ctx: *Ctx, args: []const [:0]const u8) !void {
    var opts = try parseNewArgs(ctx, args);
    if (!std.mem.eql(u8, opts.template, "default")) {
        return fail("unknown template '{s}' (supported: default)", .{opts.template});
    }
    if (!validName(opts.name)) {
        return fail(
            "invalid name '{s}': use lowercase letters, digits and underscores, " ++
                "starting with a letter",
            .{opts.name},
        );
    }
    if (exists(ctx, opts.dest)) return fail("'{s}' already exists", .{opts.dest});

    const templates = templatesDir(ctx) orelse
        return fail("templates not found (set PGZX_ROOT or install the pgzx bundle)", .{});
    const src = try pathJoin(ctx, &.{ templates, opts.template });
    if (!exists(ctx, src)) {
        return fail(
            "template '{s}' not found in {s} " ++
                "(run from a checkout or install the release bundle)",
            .{ opts.template, templates },
        );
    }

    try copyTemplate(ctx.io, ctx.arena, src, opts.dest, opts.name);
    try configureDependency(ctx, &opts);
    try fingerprint(ctx, opts.dest);

    try ctx.out.print("Created pgzx extension '{s}' in {s} (template: {s})\n", .{
        opts.name, opts.dest, opts.template,
    });
    try ctx.out.writeAll("Next:\n");
    try ctx.out.print(
        "  cd {s}\n  eval \"$(pgzx env)\"   # or: direnv allow\n  pgzx doctor\n",
        .{opts.dest},
    );
}

fn configureDependency(ctx: *Ctx, opts: *const NewOptions) !void {
    if (opts.no_fetch) return;
    const zon_path = try pathJoin(ctx, &.{ opts.dest, "build.zig.zon" });
    const zon = try readFile(ctx, zon_path);
    if (opts.ref == null and hasActiveHash(zon)) return;

    const chosen_ref = opts.ref orelse blk: {
        const v = try version(ctx);
        break :blk if (!std.mem.eql(u8, v, "dev")) v else "main";
    };
    const url = if (std.mem.eql(u8, chosen_ref, "main"))
        "https://github.com/barddoo/pgzx/archive/main.tar.gz"
    else
        try std.fmt.allocPrint(
            ctx.arena,
            "https://github.com/barddoo/pgzx/archive/refs/tags/{s}.tar.gz",
            .{chosen_ref},
        );

    if (ctx.run(&.{ "zig", "fetch", "--save=pgzx", url }, opts.dest)) |res| {
        if (!res.ok) warn("zig fetch failed; set the pgzx dependency in {s} by hand", .{zon_path});
    } else |_| {
        warn("zig not found; run 'zig fetch --save=pgzx <url>' in {s} " ++
            "before building", .{opts.dest});
    }
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(name[0] >= 'a' and name[0] <= 'z')) return false;
    for (name[1..]) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    return true;
}

fn hasActiveHash(zon: []const u8) bool {
    var it = std.mem.splitScalar(u8, zon, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, trim(line), ".hash")) return true;
    }
    return false;
}

fn copyTemplate(
    io: Io,
    alloc: Allocator,
    src: []const u8,
    dest: []const u8,
    name: []const u8,
) !void {
    var src_dir = try cwd().openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    try cwd().createDirPath(io, dest);
    while (try walker.next(io)) |entry| {
        const rel = try std.mem.replaceOwned(u8, alloc, entry.path, "my_extension", name);
        const target = try std.fs.path.join(alloc, &.{ dest, rel });
        switch (entry.kind) {
            .directory => try cwd().createDirPath(io, target),
            .file => {
                const data = try entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited);
                const replaced = try std.mem.replaceOwned(u8, alloc, data, "my_extension", name);
                try cwd().writeFile(io, .{ .sub_path = target, .data = replaced });
            },
            else => {},
        }
    }
}

pub fn cmdFingerprint(ctx: *Ctx) !void {
    try fingerprint(ctx, try projectRoot(ctx));
}

fn fingerprint(ctx: *Ctx, dir: []const u8) !void {
    const zon_path = try pathJoin(ctx, &.{ dir, "build.zig.zon" });
    if (!exists(ctx, zon_path)) return;

    const res = try ctx.run(&.{ "zig", "build", "--fetch" }, dir);
    var combined: std.ArrayList(u8) = .empty;
    try combined.appendSlice(ctx.arena, res.stdout);
    try combined.appendSlice(ctx.arena, res.stderr);

    const fp = parseFingerprint(combined.items) orelse return;
    const zon = try readFile(ctx, zon_path);
    const updated = try setFingerprint(ctx.arena, zon, fp);
    try writeFile(ctx, zon_path, updated);
    try ctx.out.print("fingerprint: {s}\n", .{fp});
}

fn parseFingerprint(text: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "use this value: ", "suggested value: " };
    for (markers) |marker| {
        const idx = std.mem.indexOf(u8, text, marker) orelse continue;
        const rest = text[idx + marker.len ..];
        const hex_idx = std.mem.indexOf(u8, rest, "0x") orelse continue;
        const candidate = rest[hex_idx..];
        var end: usize = 2;
        while (end < candidate.len and std.ascii.isHex(candidate[end])) : (end += 1) {}
        if (end > 2) return candidate[0..end];
    }
    return null;
}

fn setFingerprint(alloc: Allocator, zon: []const u8, fp: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, zon, ".fingerprint")) |idx| {
        const hex_idx = std.mem.indexOfPos(u8, zon, idx, "0x") orelse return alloc.dupe(u8, zon);
        var hex_end = hex_idx + 2;
        while (hex_end < zon.len and std.ascii.isHex(zon[hex_end])) : (hex_end += 1) {}

        const out = try alloc.alloc(u8, zon.len - (hex_end - hex_idx) + fp.len);
        @memcpy(out[0..hex_idx], zon[0..hex_idx]);
        @memcpy(out[hex_idx..][0..fp.len], fp);
        @memcpy(out[hex_idx + fp.len ..], zon[hex_end..]);
        return out;
    }

    const name_idx = std.mem.indexOf(u8, zon, ".name =") orelse return alloc.dupe(u8, zon);
    const line_end = std.mem.indexOfScalarPos(u8, zon, name_idx, '\n') orelse zon.len;
    const line_start = std.mem.lastIndexOfScalar(u8, zon[0..name_idx], '\n');
    const indent_start = if (line_start) |s| s + 1 else 0;
    var indent_end = indent_start;
    while (indent_end < zon.len and
        (zon[indent_end] == ' ' or zon[indent_end] == '\t')) : (indent_end += 1)
    {}
    const indent = zon[indent_start..indent_end];

    const prefix = ".fingerprint = ";
    const insert_len = 1 + indent.len + prefix.len + fp.len + 1;
    const out = try alloc.alloc(u8, zon.len + insert_len);
    var i: usize = 0;
    @memcpy(out[i..][0..line_end], zon[0..line_end]);
    i += line_end;
    out[i] = '\n';
    i += 1;
    @memcpy(out[i..][0..indent.len], indent);
    i += indent.len;
    @memcpy(out[i..][0..prefix.len], prefix);
    i += prefix.len;
    @memcpy(out[i..][0..fp.len], fp);
    i += fp.len;
    out[i] = ',';
    i += 1;
    @memcpy(out[i..], zon[line_end..]);
    return out;
}

const testing = std.testing;

test "validName accepts project-style names" {
    try testing.expect(validName("demo"));
    try testing.expect(validName("my_extension2"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("Demo"));
    try testing.expect(!validName("2demo"));
    try testing.expect(!validName("my-extension"));
}

test "hasActiveHash ignores the commented template hash" {
    try testing.expect(!hasActiveHash("    // .hash = \"...\","));
    try testing.expect(hasActiveHash("    .hash = \"abc\","));
    try testing.expect(hasActiveHash("  .hash = \"abc\","));
}

test "parseFingerprint reads both compiler messages" {
    try testing.expectEqualStrings(
        "0x1234abcd",
        parseFingerprint("use this value: 0x1234abcd\n").?,
    );
    try testing.expectEqualStrings(
        "0xdeadbeef",
        parseFingerprint("a\nsuggested value: 0xdeadbeef trailing").?,
    );
    try testing.expect(parseFingerprint("nothing here") == null);
}

test "setFingerprint replaces an existing value" {
    const zon = ".{\n    .name = .demo,\n    .fingerprint = 0x1111,\n}\n";
    const out = try setFingerprint(testing.allocator, zon, "0x2222");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        ".{\n    .name = .demo,\n    .fingerprint = 0x2222,\n}\n",
        out,
    );
}

test "setFingerprint inserts after the name" {
    const zon = ".{\n    .name = .demo,\n    .version = \"0.1.0\",\n}\n";
    const out = try setFingerprint(testing.allocator, zon, "0xabc");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        ".{\n    .name = .demo,\n    .fingerprint = 0xabc,\n    .version = \"0.1.0\",\n}\n",
        out,
    );
}

test "copyTemplate renames paths and replaces contents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "tpl/src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "tpl/build.zig",
        .data = "const name = \"my_extension\";\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "tpl/src/my_extension.zig",
        .data = "pub const name = \"my_extension\";\n",
    });

    var real_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(testing.io, &real_path_buffer);
    const base = real_path_buffer[0..real_len];

    const src = try std.fs.path.join(testing.allocator, &.{ base, "tpl" });
    defer testing.allocator.free(src);
    const dest = try std.fs.path.join(testing.allocator, &.{ base, "out" });
    defer testing.allocator.free(dest);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try copyTemplate(testing.io, arena_state.allocator(), src, dest, "demo");

    const renamed = try std.fs.path.join(testing.allocator, &.{ dest, "src", "demo.zig" });
    defer testing.allocator.free(renamed);
    const data = try cwd().readFileAlloc(testing.io, renamed, testing.allocator, .unlimited);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("pub const name = \"demo\";\n", data);

    const old = try std.fs.path.join(testing.allocator, &.{ dest, "src", "my_extension.zig" });
    defer testing.allocator.free(old);
    try testing.expectError(error.FileNotFound, cwd().access(testing.io, old, .{}));
}
