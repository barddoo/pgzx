//! `pgzx doctor`: check the toolchain, PostgreSQL install and project setup.

const std = @import("std");

const context = @import("context.zig");
const environment = @import("environment.zig");

const Ctx = context.Ctx;
const exists = context.exists;
const isWritable = context.isWritable;
const pathJoin = context.pathJoin;
const projectRoot = context.projectRoot;
const templatesDir = context.templatesDir;
const trim = context.trim;
const version = context.version;

const pgConfig = environment.pgConfig;
const pgConfigBin = environment.pgConfigBin;
const pgHome = environment.pgHome;
const portForClusterDir = environment.portForClusterDir;
const resolveClusterName = environment.resolveClusterName;
const resolveIncludeDirs = environment.resolveIncludeDirs;
const socketPath = environment.socketPath;
const socketPathLimit = environment.socketPathLimit;

pub fn cmdDoctor(ctx: *Ctx) !void {
    var failures: usize = 0;
    const root = try projectRoot(ctx);
    try ctx.out.print("pgzx {s}\n", .{try version(ctx)});
    try ctx.out.print("project: {s}\n", .{root});

    doctorZig(ctx, &failures);
    try doctorPg(ctx, &failures);
    try doctorHeaders(ctx, try resolveIncludeDirs(ctx));
    try doctorCluster(ctx, root, &failures);
    try doctorTemplates(ctx);

    if (failures != 0) {
        try ctx.err.print("\n{d} check(s) failed\n", .{failures});
        return error.UserError;
    }
    try ctx.out.writeAll("\nall checks passed\n");
}

fn doctorZig(ctx: *Ctx, failures: *usize) void {
    const res = ctx.run(&.{ "zig", "version" }, null) catch {
        ctx.out.writeAll("  [fail] zig not found: https://ziglang.org/download/\n") catch {};
        failures.* += 1;
        return;
    };
    if (!res.ok) {
        ctx.out.writeAll("  [fail] zig not found: https://ziglang.org/download/\n") catch {};
        failures.* += 1;
        return;
    }
    const v = trim(res.stdout);
    if (versionAtLeast(v, "0.17.0")) {
        ctx.out.print("  [ok]   zig {s}\n", .{v}) catch {};
    } else {
        ctx.out.print("  [fail] zig {s} is too old (need 0.17 or newer)\n", .{v}) catch {};
        failures.* += 1;
    }
}

fn doctorPg(ctx: *Ctx, failures: *usize) !void {
    const pg_config = pgConfigBin(ctx);
    const res = ctx.run(&.{ pg_config, "--version" }, null) catch null;
    if (res == null or !res.?.ok) {
        try ctx.out.print(
            "  [fail] {s} not found: install PostgreSQL with development headers\n",
            .{pg_config},
        );
        try ctx.out.writeAll("         Debian: sudo apt install postgresql-19 " ++
            "postgresql-server-dev-19\n");
        try ctx.out.writeAll("         macOS:  brew install postgresql@19\n");
        failures.* += 1;
        return;
    }
    try ctx.out.print("  [ok]   {s} ({s})\n", .{ pg_config, trim(res.?.stdout) });
    try ctx.out.print("         PG_HOME={s}\n", .{try pgHome(ctx)});
    try doctorPostgres(ctx, failures);
}

fn doctorCluster(ctx: *Ctx, root: []const u8, failures: *usize) !void {
    const cluster_dir = ctx.get("PGZX_CLUSTER_DIR") orelse
        try pathJoin(ctx, &.{ root, "out", "pg" });
    var probe: []const u8 = cluster_dir;
    while (!exists(ctx, probe)) {
        const parent = std.fs.path.dirname(probe) orelse break;
        if (std.mem.eql(u8, parent, probe)) break;
        probe = parent;
    }
    if (!isWritable(ctx, probe)) {
        try ctx.out.print("  [fail] cannot create cluster dir {s}\n", .{cluster_dir});
        try ctx.out.writeAll("         set PGZX_CLUSTER_DIR to a writable directory\n");
        failures.* += 1;
        return;
    }
    if (exists(ctx, cluster_dir)) {
        try ctx.out.print("  [ok]   cluster dir {s}\n", .{cluster_dir});
    } else {
        try ctx.out.print("  [ok]   cluster dir {s} (will be created)\n", .{cluster_dir});
    }
    try doctorSocketPath(ctx, cluster_dir, failures);
}

fn doctorSocketPath(ctx: *Ctx, cluster_base: []const u8, failures: *usize) !void {
    const limit = socketPathLimit();
    if (limit == 0) return;
    const name = resolveClusterName(ctx, &.{});
    const cluster_dir = try pathJoin(ctx, &.{ cluster_base, name });
    const socket_dir = ctx.get("PG_SOCKET_DIR") orelse
        try pathJoin(ctx, &.{ cluster_base, "run" });
    const port = try portForClusterDir(ctx, cluster_dir);
    const path = try socketPath(ctx, socket_dir, port);
    if (path.len <= limit) {
        try ctx.out.print("  [ok]   socket path {s}\n", .{path});
        return;
    }
    try ctx.out.print("  [fail] unix socket path is {d} bytes (max {d})\n", .{
        path.len,
        limit,
    });
    try ctx.out.print("         {s}\n", .{path});
    try ctx.out.print("         set PG_SOCKET_DIR to a shorter directory, e.g. /tmp/pgzx-{s}\n", .{
        name,
    });
    failures.* += 1;
}

fn doctorTemplates(ctx: *Ctx) !void {
    const dir = templatesDir(ctx) orelse {
        try ctx.out.writeAll("  [warn] templates not found " ++
            "(set PGZX_ROOT or install the pgzx bundle)\n");
        return;
    };
    if (exists(ctx, dir)) {
        try ctx.out.print("  [ok]   templates in {s}\n", .{dir});
    } else {
        try ctx.out.writeAll("  [warn] templates not found\n");
    }
}

fn doctorPostgres(ctx: *Ctx, failures: *usize) !void {
    const includedir = try pgConfig(ctx, "--includedir-server");
    const header = try pathJoin(ctx, &.{ includedir, "postgres.h" });
    if (exists(ctx, header)) {
        try ctx.out.writeAll("  [ok]   server headers\n");
    } else {
        try ctx.out.writeAll("  [fail] server headers missing: " ++
            "install the PostgreSQL server dev package\n");
        failures.* += 1;
    }

    const pgxs = try pgConfig(ctx, "--pgxs");
    if (pgxs.len != 0 and exists(ctx, pgxs)) {
        try ctx.out.writeAll("  [ok]   pgxs\n");
    } else {
        try ctx.out.writeAll("  [fail] pgxs missing: install the PostgreSQL server dev package\n");
        failures.* += 1;
    }

    const lib_dir = try pgConfig(ctx, "--pkglibdir");
    const shared = try pgConfig(ctx, "--sharedir");
    const ext_dir = try pathJoin(ctx, &.{ shared, "extension" });
    if (isWritable(ctx, lib_dir) and isWritable(ctx, ext_dir)) {
        try ctx.out.writeAll("  [ok]   extension install dirs are writable\n");
    } else {
        try ctx.out.writeAll("  [fail] extension install dirs are not writable\n");
        try ctx.out.print("         sudo chown -R \"$(id -un)\" {s} {s}\n", .{ lib_dir, ext_dir });
        try ctx.out.writeAll("         or use a user-owned PostgreSQL (Homebrew) " ++
            "or the Docker image\n");
        failures.* += 1;
    }
}

fn doctorHeaders(ctx: *Ctx, include_dirs: []const u8) !void {
    var missing: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "openssl/ssl.h", "gssapi/gssapi.h" }) |header| {
        var found = false;
        var it = std.mem.splitScalar(u8, include_dirs, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const p = try pathJoin(ctx, &.{ dir, header });
            if (exists(ctx, p)) {
                found = true;
                break;
            }
        }
        if (!found) {
            for ([_][]const u8{ "/usr/include", "/usr/local/include" }) |dir| {
                const p = try pathJoin(ctx, &.{ dir, header });
                if (exists(ctx, p)) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            if (missing.items.len != 0) try missing.appendSlice(ctx.arena, ", ");
            try missing.appendSlice(ctx.arena, header);
        }
    }
    if (missing.items.len != 0) {
        try ctx.out.print("  [warn] missing C headers: {s}\n", .{missing.items});
        try ctx.out.writeAll("         Debian: sudo apt install libssl-dev libkrb5-dev\n");
        try ctx.out.writeAll("         macOS:  brew install openssl@3 krb5\n");
    } else {
        try ctx.out.writeAll("  [ok]   C headers for the Postgres translation\n");
    }
}

fn versionAtLeast(actual: []const u8, wanted: []const u8) bool {
    var a_it = std.mem.splitScalar(u8, actual, '.');
    var b_it = std.mem.splitScalar(u8, wanted, '.');
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const a = std.fmt.parseInt(usize, a_it.next() orelse "0", 10) catch 0;
        const b = std.fmt.parseInt(usize, b_it.next() orelse "0", 10) catch 0;
        if (a > b) return true;
        if (a < b) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// new / fingerprint
// ---------------------------------------------------------------------------

test "versionAtLeast compares up to three components" {
    try std.testing.expect(versionAtLeast("0.17.1", "0.17.0"));
    try std.testing.expect(versionAtLeast("0.17.0", "0.17.0"));
    try std.testing.expect(versionAtLeast("0.18.0", "0.17.9"));
    try std.testing.expect(!versionAtLeast("0.16.9", "0.17.0"));
    try std.testing.expect(!versionAtLeast("0.17", "0.17.1"));
}
