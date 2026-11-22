//! PostgreSQL discovery and the project environment (`pgzx env`).

const std = @import("std");
const builtin = @import("builtin");

const context = @import("context.zig");
const Ctx = context.Ctx;
const fail = context.fail;
const exists = context.exists;
const pathJoin = context.pathJoin;
const readFile = context.readFile;
const shellQuote = context.shellQuote;
const projectRoot = context.projectRoot;
const trim = context.trim;
const writeFile = context.writeFile;

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

/// Environment for subprocesses that talk to a specific cluster.
///
/// `PGUSER`/`PGDATABASE` are dropped: an exported value from another project's
/// `eval "$(pgzx env)"` must not leak into `initdb` or the init scripts, where
/// the role does not exist yet.
pub fn clusterEnv(
    ctx: *Ctx,
    l: *const Layout,
    port: ?[]const u8,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(ctx.gpa);
    errdefer map.deinit();
    for (ctx.environ.keys(), ctx.environ.values()) |key, value| {
        if (std.mem.eql(u8, key, "PGUSER") or std.mem.eql(u8, key, "PGDATABASE")) continue;
        try map.put(key, value);
    }
    try map.put("PGHOST", l.socket_dir);
    try map.put("PGDATA", l.data_dir);
    if (port) |p| try map.put("PGPORT", p);
    return map;
}

// ---------------------------------------------------------------------------
// Cluster state
// ---------------------------------------------------------------------------

pub const state_file_name = "cluster.conf";

pub const ClusterState = struct {
    name: []const u8,
    database: []const u8,
    user: []const u8,
    port: []const u8,
};

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseLine(line: []const u8) ?KeyValue {
    const t = trim(line);
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    return .{ .key = trim(t[0..eq]), .value = trim(t[eq + 1 ..]) };
}

/// Extract the numeric value of a `postgresql.conf` setting such as
/// `port = 5433`, `port='5433'` or `port = 5433  # comment`.
pub fn parsePortValue(value: []const u8) ?[]const u8 {
    var v = trim(value);
    if (v.len >= 2 and (v[0] == '\'' or v[0] == '"')) {
        const end = std.mem.indexOfScalar(u8, v[1..], v[0]) orelse return null;
        v = v[1..][0..end];
    } else {
        var end: usize = 0;
        while (end < v.len and std.ascii.isDigit(v[end])) : (end += 1) {}
        v = v[0..end];
    }
    if (v.len == 0) return null;
    for (v) |ch| if (!std.ascii.isDigit(ch)) return null;
    return v;
}

fn parseConfPort(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const kv = parseLine(line) orelse continue;
        if (!std.mem.eql(u8, kv.key, "port")) continue;
        if (parsePortValue(kv.value)) |port| found = port;
    }
    return found;
}

pub fn portFromConf(ctx: *Ctx, l: *const Layout) ?[]const u8 {
    const path = pathJoin(ctx, &.{ l.data_dir, "postgresql.conf" }) catch return null;
    return parseConfPort(readFile(ctx, path) catch "");
}

/// Port for a cluster, from `cluster.conf` when present and from the
/// generated `postgresql.conf` for clusters created before the state file.
pub fn portForClusterDir(ctx: *Ctx, cluster_dir: []const u8) ![]const u8 {
    const state_path = try pathJoin(ctx, &.{ cluster_dir, state_file_name });
    if (parseConfPort(readFile(ctx, state_path) catch "")) |p| return p;

    const conf_path = try pathJoin(ctx, &.{ cluster_dir, "data", "postgresql.conf" });
    if (parseConfPort(readFile(ctx, conf_path) catch "")) |p| return p;
    return "5432";
}

pub fn loadClusterState(ctx: *Ctx, l: *const Layout) !ClusterState {
    const path = try pathJoin(ctx, &.{ l.cluster_dir, state_file_name });
    const data = readFile(ctx, path) catch "";
    var state: ClusterState = .{
        .name = l.cluster_name,
        .database = "postgres",
        .user = "postgres",
        .port = parseConfPort(data) orelse try portForClusterDir(ctx, l.cluster_dir),
    };

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const kv = parseLine(line) orelse continue;
        if (std.mem.eql(u8, kv.key, "name") and kv.value.len != 0) state.name = kv.value;
        if (std.mem.eql(u8, kv.key, "database") and kv.value.len != 0) {
            state.database = kv.value;
        }
        if (std.mem.eql(u8, kv.key, "user") and kv.value.len != 0) state.user = kv.value;
    }
    return state;
}

pub fn writeClusterState(ctx: *Ctx, l: *const Layout, state: ClusterState) !void {
    const path = try pathJoin(ctx, &.{ l.cluster_dir, state_file_name });
    const text = try std.fmt.allocPrint(
        ctx.arena,
        "# pgzx cluster state; rewrite with 'pgzx init --force'\n" ++
            "name={s}\ndatabase={s}\nuser={s}\nport={s}\n",
        .{ state.name, state.database, state.user, state.port },
    );
    try writeFile(ctx, path, text);
}

/// Resolve the cluster a command works on: explicit argument, then the
/// project's exported `PGZX_CLUSTER`, then the default cluster.
pub fn resolveClusterName(ctx: *Ctx, args: []const [:0]const u8) []const u8 {
    const arg: ?[]const u8 = if (args.len > 0) args[0] else null;
    return pickClusterName(arg, ctx.get("PGZX_CLUSTER"));
}

fn pickClusterName(arg: ?[]const u8, from_env: ?[]const u8) []const u8 {
    return arg orelse from_env orelse "postgres";
}

pub fn resolvePort(ctx: *Ctx, l: *const Layout) ![]const u8 {
    return (try loadClusterState(ctx, l)).port;
}

// ---------------------------------------------------------------------------
// Unix socket path length
// ---------------------------------------------------------------------------

/// Longest unix socket path the platform accepts, excluding the NUL byte.
/// `sun_path` is 108 bytes on Linux (107 usable) and 104 on macOS/BSD (103).
pub fn socketPathLimit() usize {
    return switch (builtin.os.tag) {
        .windows => 0,
        .linux, .illumos => 107,
        else => 103,
    };
}

pub fn socketPath(ctx: *Ctx, socket_dir: []const u8, port: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(ctx.arena, ".s.PGSQL.{s}", .{port});
    return pathJoin(ctx, &.{ socket_dir, name });
}

/// Fail early when the cluster's socket would not fit in `sun_path`.
pub fn checkSocketPath(ctx: *Ctx, l: *const Layout, port: []const u8) !void {
    const limit = socketPathLimit();
    if (limit == 0) return;
    const path = try socketPath(ctx, l.socket_dir, port);
    if (path.len <= limit) return;
    return fail(
        "unix socket path is {d} bytes, over the {d}-byte limit:\n" ++
            "  {s}\n" ++
            "  set PG_SOCKET_DIR to a shorter directory, e.g. /tmp/pgzx-{s}",
        .{ path.len, limit, path, l.cluster_name },
    );
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

pub fn cmdEnv(ctx: *Ctx, args: []const [:0]const u8) !void {
    const cluster_name = resolveClusterName(ctx, args);
    const l = try layout(ctx, cluster_name);
    const state = try loadClusterState(ctx, &l);
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
    try ctx.out.print("export PGZX_CLUSTER={s}\n", .{
        try shellQuote(ctx.arena, state.name),
    });
    try ctx.out.print("export PG_SOCKET_DIR={s}\n", .{try shellQuote(ctx.arena, l.socket_dir)});
    try ctx.out.print("export PGHOST={s}\n", .{try shellQuote(ctx.arena, l.socket_dir)});
    try ctx.out.print("export PGDATA={s}\n", .{try shellQuote(ctx.arena, l.data_dir)});
    try ctx.out.print("export PGPORT={s}\n", .{try shellQuote(ctx.arena, state.port)});
    try ctx.out.print("export PGUSER={s}\n", .{try shellQuote(ctx.arena, state.user)});
    try ctx.out.print("export PGDATABASE={s}\n", .{
        try shellQuote(ctx.arena, state.database),
    });
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

test "parsePortValue handles postgresql.conf syntax" {
    try std.testing.expectEqualStrings("5432", parsePortValue("5432").?);
    try std.testing.expectEqualStrings("5433", parsePortValue(" '5433' ").?);
    try std.testing.expectEqualStrings("6543", parsePortValue("\"6543\"").?);
    try std.testing.expectEqualStrings("5555", parsePortValue("5555  # local").?);
    try std.testing.expect(parsePortValue("") == null);
    try std.testing.expect(parsePortValue("'5432") == null);
    try std.testing.expect(parsePortValue("abc") == null);
}

test "parseConfPort picks the last port setting" {
    const conf =
        \\# port = 1111
        \\max_connections = 100
        \\port = 5432
        \\port = '5555'   # override
    ;
    try std.testing.expectEqualStrings("5555", parseConfPort(conf).?);
    try std.testing.expect(parseConfPort("max_connections = 100\n") == null);
}

test "pickClusterName prefers the argument, then PGZX_CLUSTER" {
    try std.testing.expectEqualStrings("mytest", pickClusterName("mytest", "other"));
    try std.testing.expectEqualStrings("other", pickClusterName(null, "other"));
    try std.testing.expectEqualStrings("postgres", pickClusterName(null, null));
}

test "socketPathLimit is usable on unix hosts" {
    if (builtin.os.tag == .windows) return;
    try std.testing.expect(socketPathLimit() >= 100);
}
