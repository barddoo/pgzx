//! pgzx - create and manage Zig PostgreSQL extension projects.
//!
//! This is the compiled CLI. It is intentionally std-only: it must build and
//! run without the pgzx library or PostgreSQL headers (but the commands that
//! talk to PostgreSQL obviously need a PostgreSQL installation).

const std = @import("std");

const Io = std.Io;

const context = @import("context.zig");
const cluster = @import("cluster.zig");
const doctor = @import("doctor.zig");
const environment = @import("environment.zig");
const new_command = @import("new.zig");

const Ctx = context.Ctx;
const fail = context.fail;
const usage = context.usage;

pub fn main(init: std.process.Init) !void {
    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [8192]u8 = undefined;
    var out_writer = Io.File.stdout().writer(init.io, &out_buffer);
    var err_writer = Io.File.stderr().writer(init.io, &err_buffer);

    var ctx: Ctx = .{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .io = init.io,
        .environ = init.environ_map,
        .out = &out_writer.interface,
        .err = &err_writer.interface,
    };

    const args = try init.minimal.args.toSlice(ctx.arena);
    dispatch(&ctx, args) catch |err| {
        ctx.out.flush() catch {};
        if (err == error.Help) return;
        if (err != error.UserError) {
            std.log.err("{t}", .{err});
        }
        ctx.err.flush() catch {};
        std.process.exit(1);
    };
    try ctx.out.flush();
    ctx.err.flush() catch {};
}

fn dispatch(ctx: *Ctx, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        try usage(ctx);
        return;
    }
    const command = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, command, "new")) return new_command.cmdNew(ctx, rest);
    if (std.mem.eql(u8, command, "env")) return environment.cmdEnv(ctx);
    if (std.mem.eql(u8, command, "init")) return cluster.cmdInit(ctx, rest);
    if (std.mem.eql(u8, command, "start")) return cluster.cmdStart(ctx, rest);
    if (std.mem.eql(u8, command, "stop")) return cluster.cmdStop(ctx, rest);
    if (std.mem.eql(u8, command, "status")) return cluster.cmdStatus(ctx, rest);
    if (std.mem.eql(u8, command, "doctor")) return doctor.cmdDoctor(ctx);
    if (std.mem.eql(u8, command, "fingerprint")) return new_command.cmdFingerprint(ctx);
    if (std.mem.eql(u8, command, "version")) {
        try ctx.out.print("{s}\n", .{try context.version(ctx)});
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--help")) return usage(ctx);

    return fail("unknown command '{s}' (run 'pgzx help')", .{command});
}
