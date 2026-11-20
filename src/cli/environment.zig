//! PostgreSQL discovery and the project environment (`pgzx env`).

const std = @import("std");
const builtin = @import("builtin");

const context = @import("context.zig");
const Ctx = context.Ctx;
const fail = context.fail;
const exists = context.exists;
const pathJoin = context.pathJoin;
const shellQuote = context.shellQuote;
const projectRoot = context.projectRoot;
const trim = context.trim;

pub fn pgConfigBin(ctx: *Ctx) []const u8 {
    return ctx.get("PG_CONFIG") orelse "pg_config";
}

fn runOutput(ctx: *Ctx, argv: []const []const u8) ![]const u8 {
    const result = try ctx.run(argv, null);
    if (!result.ok) {
        return fail("'{s}' failed: {s}", .{ argv[0], trim(result.stderr) });
    }
    return trim(result.stdout);
}

pub fn pgConfig(ctx: *Ctx, question: []const u8) ![]const u8 {
    return runOutput(ctx, &.{ pgConfigBin(ctx), question });
}

fn commonAncestor(a: []const u8, b: []const u8) []const u8 {
    var i: usize = 0;
    var last_sep: usize = 0;
    const n = @min(a.len, b.len);
    while (i < n and a[i] == b[i]) : (i += 1) {
        if (a[i] == '/') last_sep = i;
    }
    if (i == a.len and (i == b.len or b[i] == '/')) return a;
    if (i == b.len and (i == a.len or a[i] == '/')) return b;
    return if (last_sep == 0) "/" else a[0..last_sep];
}

pub fn pgHome(ctx: *Ctx) ![]const u8 {
    const bindir = try pgConfig(ctx, "--bindir");
    const pkglibdir = try pgConfig(ctx, "--pkglibdir");
    const parent = std.fs.path.dirname(bindir) orelse bindir;
    if (isSubpath(pkglibdir, parent)) return parent;
    return commonAncestor(parent, pkglibdir);
}

fn isSubpath(path: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, path, parent)) return false;
    return path.len == parent.len or path[parent.len] == '/';
}

pub const Layout = struct {
    root: []const u8,
    pg_home: []const u8,
    bin_dir: []const u8,
    cluster_name: []const u8,
    cluster_base: []const u8,
    cluster_dir: []const u8,
    data_dir: []const u8,
    log_dir: []const u8,
    log_file: []const u8,
    socket_dir: []const u8,
};

pub fn layout(ctx: *Ctx, cluster_name: []const u8) !Layout {
    const root = try projectRoot(ctx);
    const bin_dir = try pgConfig(ctx, "--bindir");
    const home = try pgHome(ctx);
    const cluster_base = ctx.get("PGZX_CLUSTER_DIR") orelse
        try pathJoin(ctx, &.{ root, "out", "pg" });
    const socket_dir = ctx.get("PG_SOCKET_DIR") orelse try pathJoin(ctx, &.{ cluster_base, "run" });
    const dir = try pathJoin(ctx, &.{ cluster_base, cluster_name });
    return .{
        .root = root,
        .pg_home = home,
        .bin_dir = bin_dir,
        .cluster_name = cluster_name,
        .cluster_base = cluster_base,
        .cluster_dir = dir,
        .data_dir = try pathJoin(ctx, &.{ dir, "data" }),
        .log_dir = try pathJoin(ctx, &.{ dir, "log" }),
        .log_file = try pathJoin(ctx, &.{ dir, "log", "server.log" }),
        .socket_dir = socket_dir,
    };
}

pub fn clusterEnv(ctx: *Ctx, l: *const Layout) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(ctx.gpa);
    errdefer map.deinit();
    try map.putAll(ctx.environ);
    try map.put("PGHOST", l.socket_dir);
    try map.put("PGDATA", l.data_dir);
    return map;
}

fn pathContains(path: []const u8, entry: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, entry)) return true;
    }
    return false;
}

fn prependPath(ctx: *Ctx, current: []const u8, entry: []const u8) ![]u8 {
    if (pathContains(current, entry)) return ctx.arena.dupe(u8, current);
    if (current.len == 0) return ctx.arena.dupe(u8, entry);
    return std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ entry, current });
}

pub fn resolveIncludeDirs(ctx: *Ctx) ![]const u8 {
    if (ctx.get("PGZX_C_INCLUDE_DIRS")) |dirs| return dirs;
    if (builtin.os.tag != .macos) return "";
    var result: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "openssl@3", "krb5" }) |pkg| {
        const res = ctx.run(&.{ "brew", "--prefix", pkg }, null) catch continue;
        if (!res.ok) continue;
        const prefix = trim(res.stdout);
        const include = try pathJoin(ctx, &.{ prefix, "include" });
        if (!exists(ctx, include)) continue;
        if (result.items.len != 0) try result.append(ctx.arena, ':');
        try result.appendSlice(ctx.arena, include);
    }
    return result.toOwnedSlice(ctx.arena);
}

// ---------------------------------------------------------------------------
// env
// ---------------------------------------------------------------------------

pub fn cmdEnv(ctx: *Ctx) !void {
    const l = try layout(ctx, "postgres");
    const include_dirs = try resolveIncludeDirs(ctx);

    var path = ctx.get("PATH") orelse "";
    path = try prependPath(ctx, path, l.bin_dir);
    const pgxs = pgConfig(ctx, "--pgxs") catch "";
    if (pgxs.len != 0) {
        const src_dir = std.fs.path.dirname(std.fs.path.dirname(pgxs) orelse pgxs) orelse pgxs;
        const regress = try pathJoin(ctx, &.{ src_dir, "test", "regress" });
        if (exists(ctx, regress)) path = try prependPath(ctx, path, regress);
    }

    try ctx.out.print("export PRJ_ROOT={s}\n", .{try shellQuote(ctx.arena, l.root)});
    try ctx.out.print("export PG_HOME={s}\n", .{try shellQuote(ctx.arena, l.pg_home)});
    try ctx.out.print("export PGZX_CLUSTER_DIR={s}\n", .{
        try shellQuote(ctx.arena, l.cluster_base),
    });
    try ctx.out.print("export PG_SOCKET_DIR={s}\n", .{try shellQuote(ctx.arena, l.socket_dir)});
    try ctx.out.print("export PGHOST={s}\n", .{try shellQuote(ctx.arena, l.socket_dir)});
    if (include_dirs.len != 0) {
        try ctx.out.print("export PGZX_C_INCLUDE_DIRS={s}\n", .{
            try shellQuote(ctx.arena, include_dirs),
        });
    }
    if (ctx.get("ZIG_LOCAL_CACHE_DIR") == null) {
        const cache_base = ctx.get("XDG_CACHE_HOME") orelse
            try std.fmt.allocPrint(ctx.arena, "{s}/.cache", .{ctx.get("HOME") orelse ""});
        const cache = try pathJoin(ctx, &.{ cache_base, "zig-pgzx" });
        try ctx.out.print("export ZIG_LOCAL_CACHE_DIR={s}\n", .{try shellQuote(ctx.arena, cache)});
    }
    try ctx.out.print("export PATH={s}\n", .{try shellQuote(ctx.arena, path)});
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

test "isSubpath respects component boundaries" {
    try std.testing.expect(isSubpath("/a/b/c", "/a/b"));
    try std.testing.expect(isSubpath("/a/b", "/a/b"));
    try std.testing.expect(!isSubpath("/a/bc", "/a/b"));
    try std.testing.expect(!isSubpath("/a", "/a/b"));
}

test "commonAncestor finds the shared prefix" {
    try std.testing.expectEqualStrings("/a/b", commonAncestor("/a/b/c", "/a/b/d"));
    try std.testing.expectEqualStrings("/", commonAncestor("/a", "/b"));
    try std.testing.expectEqualStrings("/a/b", commonAncestor("/a/b/c", "/a/b"));
}

test "pathContains matches whole PATH entries" {
    try std.testing.expect(pathContains("/usr/bin:/bin", "/bin"));
    try std.testing.expect(!pathContains("/usr/bin:/bin", "/usr"));
}
