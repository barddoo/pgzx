const std = @import("std");

pub const Build = @import("src/pgzx/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var pgbuild = Build.create(b, .{
        .target = target,
        .optimize = optimize,
    });

    const steps = .{
        .check = b.step("check", "Check if project compiles"),
        .test_pure = b.step("test", "Run pure-Zig tests (no Postgres server)"),
        .docs = b.step("docs", "Generate documentation"),
        .serve_docs = b.step("serve_docs", "Docs HTTP server http://localhost:8080/#docs.pgzx"),

        // Unit tests installer target
        // Optionally build and install the extension, so we can hook up with t a debugger and run tests manually.
        .install_unit = b.step("install-unit", "Install unit tests extension (for manual testing)"),

        .unit = b.step("unit", "Run pgzx unit tests"),
    };

    // pgzx_pgsys module: C bindings to Postgres
    const pgzx_pgsys = blk: {
        // Translate the Postgres headers once; the module wraps the result.
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("./src/pgzx/c/include/headers.h"),
            .target = target,
            .optimize = optimize,
        });

        // Postgres headers first: PG headers included from subdirectories
        // (e.g. storage/bufpage.h including "varatt.h") must resolve to the
        // real files, with our c/include shims only as a fallback (PG15 has
        // no server varatt.h at all).
        translate_c.addIncludePath(.{
            .cwd_relative = pgbuild.getIncludeServerDir(),
        });

        // Internal C headers (libpqsrv.h re-export, varatt.h PG15 shim)
        translate_c.addIncludePath(b.path("./src/pgzx/c/include/"));

        // Postgres Headers
        translate_c.addIncludePath(.{
            .cwd_relative = pgbuild.getIncludeDir(),
        });

        // Host C headers: libpq-be.h pulls in openssl/ssl.h and gssapi.h.
        // translate-c does not add the system include dirs on its own.
        // The multiarch dir is where Debian keeps opensslconf.h; add the common
        // ones so this works on both x86_64 and aarch64 hosts.
        translate_c.addIncludePath(.{
            .cwd_relative = "/usr/include",
        });
        translate_c.addIncludePath(.{
            .cwd_relative = "/usr/include/x86_64-linux-gnu",
        });
        translate_c.addIncludePath(.{
            .cwd_relative = "/usr/include/aarch64-linux-gnu",
        });

        // Extra host include dirs exported by the dev shell, for platforms where
        // openssl/krb5 headers are not in /usr/include (e.g. the nix store on
        // macOS). Colon-separated list, set as PGZX_C_INCLUDE_DIRS.
        if (b.graph.environ_map.get("PGZX_C_INCLUDE_DIRS")) |dirs| {
            var it = std.mem.tokenizeScalar(u8, dirs, ':');
            while (it.next()) |dir| {
                translate_c.addIncludePath(.{ .cwd_relative = dir });
            }
        }

        const module = translate_c.createModule();

        // Internal C headers
        module.addIncludePath(b.path("./src/pgzx/c/include/"));

        // libpq support
        module.addCSourceFiles(.{
            .files = &[_][]const u8{
                "./src/pgzx/c/libpqsrv.c",
            },
            .flags = &[_][]const u8{
                "-I", pgbuild.getIncludeDir(),
                "-I", pgbuild.getIncludeServerDir(),
            },
        });
        // Explicit path: for a non-native target (e.g. -Dtarget with a pinned
        // glibc) zig does not search system library dirs, so "pq" would not
        // be found via the native strategy.
        module.addLibraryPath(.{
            .cwd_relative = pgbuild.getLibDir(),
        });
        module.linkSystemLibrary("pq", .{});

        break :blk module;
    };

    // codegen
    // The codegen produces Zig files that are imported as modules by pgzx.
    const node_tags_src = blk: {
        const tool_module = b.createModule(.{
            .root_source_file = b.path("./tools/gennodetags/main.zig"),
            .target = b.graph.host,
            .link_libc = true,
        });
        tool_module.addIncludePath(.{ .cwd_relative = pgbuild.getIncludeServerDir() });
        tool_module.addIncludePath(.{ .cwd_relative = pgbuild.getIncludeDir() });

        const tool = b.addExecutable(.{
            .name = "gennodetags",
            .root_module = tool_module,
        });

        const tool_step = b.addRunArtifact(tool);
        break :blk tool_step.addOutputFileArg("nodetags.zig");
    };

    // pgzx: main project module.
    // This module re-exports pgzx_pgsys, other generated modules, and utility functions.
    const pgzx = blk: {
        const module = b.addModule("pgzx", .{
            .root_source_file = b.path("./src/pgzx.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("pgzx_pgsys", pgzx_pgsys);
        module.addAnonymousImport("gen_node_tags", .{
            .root_source_file = node_tags_src,
            .imports = &.{
                .{ .name = "pgzx_pgsys", .module = pgzx_pgsys },
            },
        });

        break :blk module;
    };

    // docs step
    {
        // Internal target to build the docs from the document. The generated
        // documentation is installed in the <prefix>/share/pgzx/doc folder.
        const obj = b.addObject(.{
            .name = "docs",
            .root_module = pgzx,
        });

        // `check` compiles the module without installing or generating docs.
        steps.check.dependOn(&obj.step);

        const install_docs = b.addInstallDirectory(.{
            .source_dir = obj.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "share/pgzx/docs",
        });
        steps.docs.dependOn(&install_docs.step);

        const del_docs = b.addSystemCommand(&[_][]const u8{
            "rm", "-fr", "./docs",
        });
        const copy_docs = b.addSystemCommand(&[_][]const u8{
            "cp", "-fr", "./zig-out/share/pgzx/docs", ".",
        });

        // Only delete the checked-in docs after the build succeeds, so a
        // failed build never leaves `./docs` empty.
        del_docs.step.dependOn(&install_docs.step);
        copy_docs.step.dependOn(&del_docs.step);
        steps.docs.dependOn(&copy_docs.step);

        // Use python to serve the docs via http.
        const serve_docs = b.addSystemCommand(&[_][]const u8{
            "python3", "-m", "http.server", "8080", "--directory", "./docs",
        });
        serve_docs.step.dependOn(&copy_docs.step);
        steps.serve_docs.dependOn(&serve_docs.step);
    }

    // Pure-Zig tests: run under `zig test` for modules that do not depend on a
    // live Postgres server (e.g. `meta`). Fast feedback, no PG required.
    {
        const pure_test_module = b.createModule(.{
            .root_source_file = b.path("src/pure_tests.zig"),
            .target = target,
            .optimize = optimize,
        });
        const pure_tests = b.addTest(.{
            .root_module = pure_test_module,
        });
        const run_pure_tests = b.addRunArtifact(pure_tests);
        steps.test_pure.dependOn(&run_pure_tests.step);
    }

    // Unit test extension
    const test_ext = blk: {
        const test_options = b.addOptions();
        test_options.addOption(bool, "testfn", true);

        const tests = pgbuild.addInstallExtension(.{
            .name = "pgzx_unit",
            .version = .{ .major = 0, .minor = 1 },
            .root_source_file = b.path("src/testing.zig"),
            .root_dir = "src/testing",
            .link_libc = true,
            .link_allow_shlib_undefined = true,
        });
        tests.lib.root_module.addOptions("build_options", test_options);

        tests.lib.root_module.addIncludePath(b.path("./src/pgzx/c/include/"));

        tests.lib.root_module.addImport("pgzx_pgsys", pgzx_pgsys);
        tests.lib.root_module.addImport("pgzx", pgzx);
        tests.lib.root_module.addAnonymousImport("gen_node_tags", .{
            .root_source_file = node_tags_src,
            .imports = &.{
                .{ .name = "pgzx_pgsys", .module = pgzx_pgsys },
            },
        });

        steps.install_unit.dependOn(&tests.step);

        break :blk tests;
    };

    // Unit test runner
    {
        const psql_run_tests = pgbuild.addRunTests(.{
            .name = "pgzx_unit",
            .db_user = "postgres",
            .db_port = 5432,
        });

        psql_run_tests.step.dependOn(&test_ext.step);
        steps.unit.dependOn(&psql_run_tests.step);
    }
}
