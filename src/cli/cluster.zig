//! Local PostgreSQL cluster commands: init, start, stop and status.

const std = @import("std");

const context = @import("context.zig");
const environment = @import("environment.zig");

const Ctx = context.Ctx;
const cwd = context.cwd;
const fail = context.fail;
const makePath = context.makePath;
const pathJoin = context.pathJoin;
const readFile = context.readFile;
const trim = context.trim;
const writeFile = context.writeFile;

const Layout = environment.Layout;
const clusterEnv = environment.clusterEnv;
const layout = environment.layout;
const pgConfig = environment.pgConfig;

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
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "-s") or
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
        \\
    );
}

pub fn cmdInit(ctx: *Ctx, args: []const [:0]const u8) !void {
    const opts = parseInitArgs(ctx, args) catch |err| {
        if (err == error.UserError or err == error.Help) return;
        return err;
    };
    const l = try layout(ctx, opts.cluster_name);
    try makeClusterDirs(ctx, &l);

    var env = try clusterEnv(ctx, &l);
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
    const cluster_name = if (args.len > 0) args[0] else "postgres";
    const l = try layout(ctx, cluster_name);
    try makePath(ctx, l.socket_dir);
    var env = try clusterEnv(ctx, &l);
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
    const cluster_name = if (args.len > 0) args[0] else "postgres";
    const l = try layout(ctx, cluster_name);
    var env = try clusterEnv(ctx, &l);
    defer env.deinit();
    const pg_ctl = try pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" });
    const res = try ctx.runEnv(&.{ pg_ctl, "-D", l.data_dir, "stop" }, null, &env);
    try ctx.out.writeAll(res.stdout);
    try ctx.err.writeAll(res.stderr);
    if (!res.ok) return error.UserError;
}

pub fn cmdStatus(ctx: *Ctx, args: []const [:0]const u8) !void {
    const cluster_name = if (args.len > 0) args[0] else "postgres";
    const l = try layout(ctx, cluster_name);
    var env = try clusterEnv(ctx, &l);
    defer env.deinit();
    const pg_ctl = try pathJoin(ctx, &.{ l.bin_dir, "pg_ctl" });
    const res = try ctx.runEnv(&.{ pg_ctl, "-D", l.data_dir, "status" }, null, &env);
    try ctx.out.writeAll(res.stdout);
    try ctx.err.writeAll(res.stderr);
    if (!res.ok) return error.UserError;
}
