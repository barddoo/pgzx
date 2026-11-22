//! Local PostgreSQL cluster commands: init, start, stop and status.

const std = @import("std");

const context = @import("context.zig");
const environment = @import("environment.zig");

const Ctx = context.Ctx;
const cwd = context.cwd;
const exists = context.exists;
const fail = context.fail;
const makePath = context.makePath;
const pathJoin = context.pathJoin;
const readFile = context.readFile;
const shellQuote = context.shellQuote;
const trim = context.trim;
const writeFile = context.writeFile;

const ClusterState = environment.ClusterState;
const Layout = environment.Layout;
const checkSocketPath = environment.checkSocketPath;
const clusterEnv = environment.clusterEnv;
const layout = environment.layout;
const pgConfig = environment.pgConfig;
const portFromConf = environment.portFromConf;
const resolveClusterName = environment.resolveClusterName;
const resolvePort = environment.resolvePort;
const writeClusterState = environment.writeClusterState;

fn makeClusterDirs(ctx: *Ctx, l: *const Layout) !void {
    for ([_][]const u8{ l.cluster_dir, l.data_dir, l.log_dir, l.socket_dir }) |dir| {
        makePath(ctx, dir) catch |err| {
            return fail(
                "cannot create cluster state in '{s}': {t}\n" ++
                    "  set PGZX_CLUSTER_DIR to a writable directory",
                .{ dir, err },
            );
        };
    }
}

const InitOptions = struct {
    cluster_name: []const u8 = "postgres",
    database: []const u8 = "postgres",
    user: []const u8 = "postgres",
    port: ?[]const u8 = null,
    preload: ?[]const u8 = null,
    init_path: ?[]const u8 = null,
    postgres_conf: ?[]const u8 = null,
    force: bool = false,
};

fn parseInitArgs(ctx: *Ctx, args: []const [:0]const u8) !InitOptions {
    var opts: InitOptions = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            try initUsage(ctx);
            return error.Help;
        }
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "-s") or
            std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "-c"))
        {
            i += 1;
            if (i >= args.len) return fail("{s} needs a value", .{arg});
            if (std.mem.eql(u8, arg, "-p")) opts.port = args[i];
            if (std.mem.eql(u8, arg, "-s")) opts.preload = args[i];
            if (std.mem.eql(u8, arg, "-i")) opts.init_path = args[i];
            if (std.mem.eql(u8, arg, "-c")) opts.postgres_conf = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fail("unknown option '{s}'", .{arg});
        } else {
            try positional.append(ctx.arena, arg);
        }
    }
    if (positional.items.len > 0) opts.cluster_name = positional.items[0];
    if (positional.items.len > 1) opts.database = positional.items[1];
    if (positional.items.len > 2) opts.user = positional.items[2];
    return opts;
}

fn initUsage(ctx: *Ctx) !void {
    try ctx.out.writeAll(
        \\Usage: pgzx init [options] [cluster] [database] [user]
        \\  -p port: port to configure for the cluster database
        \\  -s lib: shared_preload_libraries to configure
        \\  -i path: directory with *.sql init scripts
        \\  -c path: directory with a custom postgresql.conf
        \\  -f, --force: delete an existing cluster and initialize it again
        \\
    );
}

pub fn cmdInit(ctx: *Ctx, args: []const [:0]const u8) !void {
    const opts = parseInitArgs(ctx, args) catch |err| {
        if (err == error.UserError or err == error.Help) return;
        return err;
    };
    const l = try layout(ctx, opts.cluster_name);
    try preflightCluster(ctx, &l, opts.force);

    // initdb and the init scripts run before the requested port and the
    // custom config are applied, so they talk to the temporary server on 5432.
    const init_port = opts.port orelse "5432";
    try checkSocketPath(ctx, &l, init_port);
    try makeClusterDirs(ctx, &l);

    var env = try clusterEnv(ctx, &l, init_port);
    defer env.deinit();

    try runInitdb(ctx, &l, &env);
    try startForInit(ctx, &l, &env);
    var server_started = true;
    defer if (server_started) stopServer(ctx, &l, &env);

    try createUserAndDb(ctx, &l, &env, opts.user, opts.database);
    if (opts.init_path) |dir| try runInitScripts(ctx, dir, opts.user, opts.database, &env);

    stopServer(ctx, &l, &env);
    server_started = false;

    if (opts.postgres_conf) |dir| try copyConfig(ctx, dir, l.data_dir);
    try writeClusterConfig(ctx, &l, &opts);

    const state: ClusterState = .{
        .name = opts.cluster_name,
        .database = opts.database,
        .user = opts.user,
        .port = try finalPort(ctx, &l, opts.port),
    };
    try writeClusterState(ctx, &l, state);
    try printInitSummary(ctx, &l, state);
}

/// The port the cluster will actually listen on: the `-p` override, else the
/// value in the final `postgresql.conf` (which a `-c` config may set).
fn finalPort(ctx: *Ctx, l: *const Layout, override: ?[]const u8) ![]const u8 {
    if (override) |port| return port;
    return portFromConf(ctx, l) orelse "5432";
}

fn directoryHasEntries(ctx: *Ctx, path: []const u8) bool {
    var dir = cwd().openDir(ctx.io, path, .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    return (it.next(ctx.io) catch null) != null;
}

fn preflightCluster(ctx: *Ctx, l: *const Layout, force: bool) !void {
    const initialized = exists(ctx, l.data_dir) and directoryHasEntries(ctx, l.data_dir);
    if (!initialized) {
        // A half-created cluster dir (no data yet) is reused; --force clears it.
        if (force and exists(ctx, l.cluster_dir)) try removeCluster(ctx, l);
        return;
    }
    if (!force) {
        return fail(
            "cluster already exists at '{s}'\n" ++
                "  use 'pgzx init --force' to delete it and initialize a fresh one",
            .{l.cluster_dir},
        );
    }
    try removeCluster(ctx, l);
}

fn removeCluster(ctx: *Ctx, l: *const Layout) !void {
    var env = try clusterEnv(ctx, l, null);
    defer env.deinit();
    stopServer(ctx, l, &env);
    cwd().deleteTree(ctx.io, l.cluster_dir) catch |err| {
        return fail("cannot remove cluster at '{s}': {t}", .{ l.cluster_dir, err });
    };
}

fn printInitSummary(ctx: *Ctx, l: *const Layout, state: ClusterState) !void {
    try ctx.out.print("initialized cluster \"{s}\"\n", .{state.name});
    try ctx.out.print("  data      {s}\n", .{l.data_dir});
    try ctx.out.print("  socket    {s}\n", .{l.socket_dir});
    try ctx.out.print("  log       {s}\n", .{l.log_file});
    try ctx.out.print("  port      {s}\n", .{state.port});
    try ctx.out.print("  user      {s}\n", .{state.user});
    try ctx.out.print("  database  {s}\n", .{state.database});
    try ctx.out.writeAll("\nnext:\n");
    try ctx.out.print("  eval \"$(pgzx env {s})\"\n", .{
        try shellQuote(ctx.arena, state.name),
    });
    try ctx.out.writeAll("  pgzx start\n");
    try ctx.out.print("  psql -U {s} -c 'select version()'\n", .{
        try shellQuote(ctx.arena, state.user),
    });
}

fn runInitdb(ctx: *Ctx, l: *const Layout, env: *std.process.Environ.Map) !void {
    const initdb = try pathJoin(ctx, &.{ l.bin_dir, "initdb" });
    const res = try ctx.runEnv(&.{ initdb, "-D", l.data_dir, "--encoding=UTF8" }, null, env);
    if (!res.ok) return fail("initdb failed:\n{s}", .{trim(res.stderr)});
}

fn startForInit(ctx: *Ctx, l: *const Layout, env: *std.process.Environ.Map) !void {
    const pg_ctl = try pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" });
    const offset = try std.fmt.allocPrint(ctx.arena, "-k {s}", .{l.socket_dir});
    const res = try ctx.runEnv(
        &.{ pg_ctl, "-t", "60", "-D", l.data_dir, "-l", l.log_file, "-o", offset, "start" },
        null,
        env,
    );
    if (res.ok) return;
    const log = readFile(ctx, l.log_file) catch "";
    return fail("failed to start PostgreSQL:\n{s}\n{s}", .{ trim(res.stderr), log });
}

fn stopServer(ctx: *Ctx, l: *const Layout, env: *std.process.Environ.Map) void {
    const pg_ctl = pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" }) catch return;
    _ = ctx.runEnv(&.{ pg_ctl, "-D", l.data_dir, "stop" }, null, env) catch {};
}

fn createUserAndDb(
    ctx: *Ctx,
    l: *const Layout,
    env: *std.process.Environ.Map,
    user: []const u8,
    database: []const u8,
) !void {
    const createuser = try pathJoin(ctx, &.{ l.bin_dir, "createuser" });
    const res = try ctx.runEnv(
        &.{ createuser, "-d", "-e", "-i", "-l", "-r", "-s", user },
        null,
        env,
    );
    if (!res.ok) return fail("createuser failed:\n{s}", .{trim(res.stderr)});
    if (std.mem.eql(u8, database, "postgres")) return;

    const createdb = try pathJoin(ctx, &.{ l.bin_dir, "createdb" });
    const db_res = try ctx.runEnv(&.{ createdb, "-U", user, database }, null, env);
    if (!db_res.ok) return fail("createdb failed:\n{s}", .{trim(db_res.stderr)});
}

fn writeClusterConfig(ctx: *Ctx, l: *const Layout, opts: *const InitOptions) !void {
    var conf: std.ArrayList(u8) = .empty;
    const conf_path = try pathJoin(ctx, &.{ l.data_dir, "postgresql.conf" });
    try conf.appendSlice(ctx.arena, try readFile(ctx, conf_path));
    try conf.appendSlice(ctx.arena, "\n");
    try appendConfig(&conf, ctx, "unix_socket_directories", l.socket_dir);
    if (opts.port) |p| try appendConfig(&conf, ctx, "port", p);
    if (opts.preload) |p| try appendConfig(&conf, ctx, "shared_preload_libraries", p);
    try writeFile(ctx, conf_path, conf.items);
}

fn appendConfig(conf: *std.ArrayList(u8), ctx: *Ctx, key: []const u8, value: []const u8) !void {
    const line = try std.fmt.allocPrint(ctx.arena, "{s}='{s}'\n", .{ key, value });
    try conf.appendSlice(ctx.arena, line);
}

fn runInitScripts(
    ctx: *Ctx,
    dir: []const u8,
    user: []const u8,
    database: []const u8,
    env: *std.process.Environ.Map,
) !void {
    var d = cwd().openDir(ctx.io, dir, .{ .iterate = true }) catch
        return fail("cannot open init script directory '{s}'", .{dir});
    defer d.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sql")) {
            try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    const psql = try pathJoin(ctx, &.{ try pgConfig(ctx, "--bindir"), "psql" });
    for (names.items) |file| {
        const full = try pathJoin(ctx, &.{ dir, file });
        const res = try ctx.runEnv(&.{ psql, "-U", user, "-d", database, "-f", full }, null, env);
        if (!res.ok) return fail("init script {s} failed:\n{s}", .{ full, trim(res.stderr) });
    }
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn copyConfig(ctx: *Ctx, src: []const u8, dest: []const u8) !void {
    var d = cwd().openDir(ctx.io, src, .{ .iterate = true }) catch
        return fail("cannot open config directory '{s}'", .{src});
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try d.readFileAlloc(ctx.io, entry.name, ctx.arena, .unlimited);
        try writeFile(ctx, try pathJoin(ctx, &.{ dest, entry.name }), data);
    }
}

pub fn cmdStart(ctx: *Ctx, args: []const [:0]const u8) !void {
    const cluster_name = resolveClusterName(ctx, args);
    const l = try layout(ctx, cluster_name);
    const port = try resolvePort(ctx, &l);
    try checkSocketPath(ctx, &l, port);
    try makePath(ctx, l.socket_dir);
    var env = try clusterEnv(ctx, &l, port);
    defer env.deinit();
    const pg_ctl = try pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" });
    const offset = try std.fmt.allocPrint(ctx.arena, "-k {s}", .{l.socket_dir});
    const res = try ctx.runEnv(
        &.{ pg_ctl, "-D", l.data_dir, "-l", l.log_file, "-o", offset, "start" },
        null,
        &env,
    );
    try ctx.out.writeAll(res.stdout);
    try ctx.err.writeAll(res.stderr);
    if (!res.ok) {
        const log = readFile(ctx, l.log_file) catch "";
        ctx.err.writeAll(log) catch {};
        return fail("failed to start PostgreSQL", .{});
    }
}

pub fn cmdStop(ctx: *Ctx, args: []const [:0]const u8) !void {
    const cluster_name = resolveClusterName(ctx, args);
    const l = try layout(ctx, cluster_name);
    var env = try clusterEnv(ctx, &l, null);
    defer env.deinit();
    const pg_ctl = try pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" });
    const res = try ctx.runEnv(&.{ pg_ctl, "-D", l.data_dir, "stop" }, null, &env);
    try ctx.out.writeAll(res.stdout);
    try ctx.err.writeAll(res.stderr);
    if (!res.ok) return error.UserError;
}

pub fn cmdStatus(ctx: *Ctx, args: []const [:0]const u8) !void {
    const cluster_name = resolveClusterName(ctx, args);
    const l = try layout(ctx, cluster_name);
    var env = try clusterEnv(ctx, &l, null);
    defer env.deinit();
    const pg_ctl = try pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" });
    const res = try ctx.runEnv(&.{ pg_ctl, "-D", l.data_dir, "status" }, null, &env);
    try ctx.out.writeAll(res.stdout);
    try ctx.err.writeAll(res.stderr);
    if (!res.ok) return error.UserError;
}
