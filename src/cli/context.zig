//! Shared context, process helpers, filesystem helpers and the installed
//! layout discovery used by all CLI commands.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const cwd = Io.Dir.cwd;

pub const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,

    pub fn get(self: *const Ctx, key: []const u8) ?[]const u8 {
        return self.environ.get(key);
    }

    const RunResult = struct {
        stdout: []u8,
        stderr: []u8,
        ok: bool,
    };

    pub fn run(self: *const Ctx, argv: []const []const u8, cwd_path: ?[]const u8) !RunResult {
        return self.runEnv(argv, cwd_path, null);
    }

    pub fn runEnv(
        self: *const Ctx,
        argv: []const []const u8,
        cwd_path: ?[]const u8,
        environ_map: ?*const std.process.Environ.Map,
    ) !RunResult {
        const result = try std.process.run(self.arena, self.io, .{
            .argv = argv,
            .cwd = if (cwd_path) |p| .{ .path = p } else .inherit,
            .environ_map = environ_map,
        });
        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .ok = result.term.success(),
        };
    }
};

pub fn fail(comptime fmt: []const u8, args: anytype) error{UserError} {
    std.log.err(fmt, args);
    return error.UserError;
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
}

pub fn exists(ctx: *Ctx, path: []const u8) bool {
    cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

pub fn readFile(ctx: *Ctx, path: []const u8) ![]u8 {
    return cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited);
}

pub fn writeFile(ctx: *Ctx, path: []const u8, data: []const u8) !void {
    try cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
}

pub fn makePath(ctx: *Ctx, path: []const u8) !void {
    try cwd().createDirPath(ctx.io, path);
}

pub fn pathJoin(ctx: *Ctx, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(ctx.arena, parts);
}

pub fn replaceAll(ctx: *Ctx, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, ctx.arena, input, needle, replacement);
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn shellQuote(alloc: Allocator, s: []const u8) ![]u8 {
    var extra: usize = 0;
    for (s) |ch| {
        if (ch == '\'') extra += 3;
    }
    const out = try alloc.alloc(u8, s.len + 2 + extra);
    out[0] = '\'';
    var i: usize = 1;
    for (s) |ch| {
        if (ch == '\'') {
            @memcpy(out[i..][0..4], "'\\''");
            i += 4;
        } else {
            out[i] = ch;
            i += 1;
        }
    }
    out[i] = '\'';
    return out;
}

pub fn currentPath(ctx: *Ctx) ![]u8 {
    return std.process.currentPathAlloc(ctx.io, ctx.arena);
}

pub fn projectRoot(ctx: *Ctx) ![]const u8 {
    if (ctx.get("PRJ_ROOT")) |root| return root;
    const start = try currentPath(ctx);
    var dir: []const u8 = start;
    while (true) {
        const zon = try pathJoin(ctx, &.{ dir, "build.zig.zon" });
        if (exists(ctx, zon)) return dir;
        const parent = std.fs.path.dirname(dir) orelse return start;
        if (std.mem.eql(u8, parent, dir)) return start;
        dir = parent;
    }
}

pub fn executableDir(ctx: *Ctx) ?[]const u8 {
    const exe = std.process.executablePathAlloc(ctx.io, ctx.arena) catch return null;
    return std.fs.path.dirname(exe) orelse exe;
}

pub fn findShareDir(ctx: *Ctx) ?[]const u8 {
    if (ctx.get("PGZX_ROOT")) |root| {
        const t = pathJoin(ctx, &.{ root, "templates" }) catch return null;
        if (exists(ctx, t)) return root;
    }
    const exe_dir = executableDir(ctx) orelse return null;
    const candidates = [_][]const []const u8{
        &.{ exe_dir, "..", "share", "pgzx" },
        &.{ exe_dir, "..", ".." },
    };
    for (candidates) |parts| {
        const dir = pathJoin(ctx, parts) catch continue;
        const t = pathJoin(ctx, &.{ dir, "templates" }) catch continue;
        if (exists(ctx, t)) return dir;
    }
    return null;
}

pub fn templatesDir(ctx: *Ctx) ?[]const u8 {
    const share = findShareDir(ctx) orelse return null;
    return pathJoin(ctx, &.{ share, "templates" }) catch null;
}

pub fn version(ctx: *Ctx) ![]const u8 {
    if (findShareDir(ctx)) |share| {
        const file = try pathJoin(ctx, &.{ share, "VERSION" });
        if (exists(ctx, file)) return trim(try readFile(ctx, file));
    }
    return "dev";
}

pub fn isWritable(ctx: *Ctx, path: []const u8) bool {
    cwd().access(ctx.io, path, .{ .write = true }) catch return false;
    return true;
}
pub fn usage(ctx: *Ctx) !void {
    try ctx.out.writeAll(
        \\Usage: pgzx <command> [options]
        \\
        \\Commands:
        \\  new <name> [dir]   Create a new extension project
        \\  env                Print export lines for the current project
        \\  init               Initialize the local PostgreSQL cluster
        \\  start              Start the local PostgreSQL cluster
        \\  stop               Stop the local PostgreSQL cluster
        \\  status             Show the local PostgreSQL cluster status
        \\  doctor             Check the development environment
        \\  fingerprint        Derive the build.zig.zon fingerprint with zig
        \\  version            Print the pgzx version
        \\  help               Show this help
        \\
        \\new options:
        \\  --template <default>   Project template (default: default)
        \\  --pgzx-ref <ref>       pgzx git ref to depend on (default: release tag)
        \\  --no-fetch             Do not resolve the dependency hash with zig fetch
        \\
        \\Environment:
        \\  PGZX_DEFAULT_TEMPLATE  Template used when --template is omitted
        \\  PGZX_ROOT              Installed pgzx share directory (auto-detected)
        \\  PG_CONFIG              pg_config to use (default: pg_config)
        \\  PGZX_CLUSTER_DIR       Cluster state directory (default: <project>/out/pg)
        \\
    );
}

// ---------------------------------------------------------------------------
// Paths and process helpers
// ---------------------------------------------------------------------------

test "shellQuote leaves a plain value intact" {
    const quoted = try shellQuote(std.testing.allocator, "/tmp/a b");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/a b'", quoted);
}

test "shellQuote escapes single quotes" {
    const quoted = try shellQuote(std.testing.allocator, "it's");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'it'\\''s'", quoted);
}

test "shellQuote handles the empty value" {
    const quoted = try shellQuote(std.testing.allocator, "");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("''", quoted);
}
