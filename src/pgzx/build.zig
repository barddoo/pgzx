const std = @import("std");

const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const AddCSourceFilesOptions = std.Build.Module.AddCSourceFilesOptions;

const Build = @This();

std_build: *std.Build,
paths: Paths,
options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
},
debug: DebugOptions,

modules: struct {
    builder: *Build = undefined,

    const Self = @This();

    fn loadModule(mods: Self, name: []const u8) *std.Build.Module {
        const dep = mods.builder.std_build.dependency("pgzx", mods.builder.options);
        return dep.module(name);
    }

    pub fn pgzx(mods: Self) *std.Build.Module {
        return mods.loadModule("pgzx");
    }

    pub fn pgsys(mods: Self) *std.Build.Module {
        return mods.loadModule("pgsys");
    }
},

// We use project to collect common build optoins and resources.
//
// When creating the docs or build and install steps, `Compile` step is
// directly configured to emit these kind of resources. Because we do not
// always want to emit everything we are forced to create separate `Compile`
// step instances for the different commands we want to run. The `Project`
// struct helps us to create properly configured resources, including
// dependencies.
//
pub const Project = struct {
    pgbuild: *Build,
    build: *std.Build,
    deps: struct {
        pgzx: *std.Build.Module,
    },
    options: std.StringArrayHashMapUnmanaged(*Step.Options),
    config: Config,

    // The `build_options` module is passed to every extension library and always
    // defines `testfn`. It is `false` for the production build, and `true` for
    // the dedicated unit test library (`test_build_options`).
    build_options: *Step.Options,
    test_build_options: *Step.Options,

    // C support
    includePaths: std.ArrayList(LazyPath),
    libraryPaths: std.ArrayList(LazyPath),
    cSourcesFiles: std.ArrayList(AddCSourceFilesOptions),

    pub const Config = struct {
        name: []const u8,
        version: ExtensionVersion,

        root_dir: []const u8,
        root_source_file: ?[]const u8 = null,

        extension_dir: ?[]const u8 = null,
    };

    pub fn init(b: *std.Build, c: Config) Project {
        const pgbuild = Build.create(b, .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .debug = .{
                .pg_config = false,
                .extension_lib = false,
            },
        });

        var proj_config = c;
        if (c.root_source_file == null) {
            const file_name = std.fmt.allocPrint(b.allocator, "{s}.zig", .{c.name}) catch unreachable;
            const src: []u8 = std.fs.path.join(b.allocator, &[_][]const u8{ c.root_dir, file_name }) catch unreachable;
            proj_config.root_source_file = src;
        }
        if (c.extension_dir == null) {
            proj_config.extension_dir = "./extension/";
        }

        const build_options = b.addOptions();
        build_options.addOption(bool, "testfn", false);

        const test_build_options = b.addOptions();
        test_build_options.addOption(bool, "testfn", true);

        return Project{
            .build = b,
            .pgbuild = pgbuild,
            .deps = .{
                .pgzx = pgbuild.modules.pgzx(),
            },
            .config = proj_config,
            .options = std.StringArrayHashMapUnmanaged(*Step.Options){},
            .build_options = build_options,
            .test_build_options = test_build_options,
            .includePaths = std.ArrayList(LazyPath).empty,
            .libraryPaths = std.ArrayList(LazyPath).empty,
            .cSourcesFiles = std.ArrayList(AddCSourceFilesOptions).empty,
        };
    }

    /// Creates an extension library and configures it with the given
    /// `build_options`. `name` overrides the project name, which is how the
    /// unit test library (`{name}_unit`) is produced.
    fn createLib(proj: Project, name: []const u8, build_options: *Step.Options) *Step.Compile {
        const lib = proj.pgbuild.addExtensionLib(.{
            .name = name,
            .version = proj.config.version,
            .root_dir = proj.config.root_dir,
            .root_source_file = proj.build.path(proj.config.root_source_file.?),
        });
        proj.configureLib(lib, build_options);
        return lib;
    }

    fn configureLib(proj: Project, lib: *Step.Compile, build_options: *Step.Options) void {
        var mod = lib.root_module;
        mod.addImport("pgzx", proj.deps.pgzx);
        mod.addOptions("build_options", build_options);

        var it = proj.options.iterator();
        while (it.next()) |kv| {
            mod.addOptions(kv.key_ptr.*, kv.value_ptr.*);
        }

        for (proj.includePaths.items) |path| {
            mod.addIncludePath(path);
        }
        for (proj.libraryPaths.items) |path| {
            mod.addLibraryPath(path);
        }
        for (proj.cSourcesFiles.items) |options| {
            mod.addCSourceFiles(options);
        }
    }

    pub fn extensionLib(proj: Project) *Step.Compile {
        return proj.createLib(proj.config.name, proj.build_options);
    }

    pub fn installExtensionLib(proj: Project) *Step.InstallFile {
        return proj.pgbuild.addInstallExtensionLibArtifact(proj.extensionLib(), proj.config.name);
    }

    pub fn installExtensionDir(proj: Project) *Step.InstallDir {
        return proj.pgbuild.addInstallExtensionDir(proj.config.extension_dir.?);
    }

    pub fn addOptions(proj: *Project, module_name: []const u8, options: *Step.Options) void {
        proj.options.put(proj.build.allocator, module_name, options) catch unreachable;
    }

    pub fn addIncludePath(proj: *Project, path: LazyPath) void {
        proj.includePaths.append(proj.build.allocator, path) catch unreachable;
    }

    pub fn addLibraryPath(proj: *Project, path: LazyPath) void {
        proj.libraryPaths.append(proj.build.allocator, path) catch unreachable;
    }

    pub fn addCSourceFiles(proj: *Project, options: AddCSourceFilesOptions) void {
        proj.cSourcesFiles.append(proj.build.allocator, options) catch unreachable;
    }

    pub const SchemaOptions = struct {
        /// Source file holding the comptime SQL schema declaration. It must not
        /// force any PostgreSQL symbol to be emitted (in particular it must not
        /// call `PG_FUNCTION_V1`/`PG_EXPORT`), because the generator is linked
        /// as an executable and cannot resolve server symbols. Defaults to
        /// `<root_dir>/schema.zig`.
        source: ?[]const u8 = null,
        /// Name of the comptime declaration in `source` that describes the SQL
        /// schema (see `pgzx.ddl`).
        declaration: []const u8 = "pgzx_sql",
        /// Output file name. Defaults to `{name}--{version}.sql`.
        file_name: ?[]const u8 = null,
        /// Destination extension directory (relative to the install prefix) to
        /// install the generated script into. Defaults to the PostgreSQL
        /// extension directory reported by `pg_config`.
        extension_dir: ?[]const u8 = null,
    };

    /// Compiles and runs a small generator that renders the extension's SQL
    /// schema (see `pgzx.ddl`) and installs the result as the versioned
    /// extension script (`<name>--<version>.sql`).
    ///
    /// The generator imports `options.source` as the `schema` module and reads
    /// the declaration named by `options.declaration`.
    pub fn addSchema(proj: Project, options: SchemaOptions) *Step.InstallFile {
        const b = proj.build;

        const file_name = options.file_name orelse b.fmt("{s}--{d}.{d}.sql", .{
            proj.config.name,
            proj.config.version.major,
            proj.config.version.minor,
        });

        const source = options.source orelse b.pathJoin(&[_][]const u8{ proj.config.root_dir, "schema.zig" });

        // The generator cannot link against the Postgres server, so the schema
        // module must only rely on comptime metadata. It is linked, stripped,
        // and optimized so that function bodies reachable only through the
        // schema declaration are discarded.
        const schema_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = proj.pgbuild.options.target,
            .optimize = .ReleaseSmall,
            .strip = true,
        });
        schema_module.addImport("pgzx", proj.deps.pgzx);
        schema_module.addOptions("build_options", proj.build_options);
        for (proj.includePaths.items) |path| {
            schema_module.addIncludePath(path);
        }
        var opt_it = proj.options.iterator();
        while (opt_it.next()) |kv| {
            schema_module.addOptions(kv.key_ptr.*, kv.value_ptr.*);
        }

        const generator_source = b.fmt(
            \\const std = @import("std");
            \\const pgzx = @import("pgzx");
            \\const schema = @import("schema");
            \\
            \\pub fn main(init: std.process.Init) !void {{
            \\    var buffer: [64 * 1024]u8 = undefined;
            \\    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
            \\    const stdout = &stdout_writer.interface;
            \\    try pgzx.ddl.render(stdout, schema.{s});
            \\    try stdout.flush();
            \\}}
            \\
        , .{options.declaration});

        const write_files = b.addWriteFiles();
        const generator_file = write_files.add("pgzx_generate_sql.zig", generator_source);

        const generator_module = b.createModule(.{
            .root_source_file = generator_file,
            .target = proj.pgbuild.options.target,
            // The generator only needs comptime metadata, but linking it as a
            // normal Debug build would drag in debug info for the extension's
            // function bodies, which reference Postgres server symbols that an
            // executable cannot resolve. Build it stripped and optimized so
            // dead code (and its debug info) is discarded.
            .optimize = .ReleaseSmall,
            .strip = true,
        });
        generator_module.addImport("pgzx", proj.deps.pgzx);
        generator_module.addImport("schema", schema_module);

        const generator = b.addExecutable(.{
            .name = "pgzx_generate_sql",
            .root_module = generator_module,
        });

        const run = b.addRunArtifact(generator);
        const generated_sql = run.captureStdOut(.{ .basename = file_name });

        const ext_dir = options.extension_dir orelse proj.pgbuild.getExtensionDir();
        return b.addInstallFileWithDir(
            generated_sql,
            .prefix,
            b.pathJoin(&[_][]const u8{ ext_dir, file_name }),
        );
    }

    pub const UnitTestOptions = struct {
        db_user: ?[]const u8 = null,
        db_host: ?[]const u8 = null,
        db_port: ?u16 = null,
        db_name: ?[]const u8 = null,
    };

    /// Builds a dedicated `{name}_unit` library with `testfn = true`, installs it
    /// and returns the step that runs `SELECT run_tests()` against it.
    ///
    /// The unit test library is installed under a distinct name so it never
    /// collides with the production extension library.
    pub fn addUnitTests(proj: Project, options: UnitTestOptions) *Step.Run {
        const test_name = std.fmt.allocPrint(proj.build.allocator, "{s}_unit", .{proj.config.name}) catch unreachable;

        const lib = proj.createLib(test_name, proj.test_build_options);
        const install = proj.pgbuild.addInstallExtensionLibArtifact(lib, test_name);

        const run = proj.pgbuild.addRunTests(.{
            .name = test_name,
            .db_user = options.db_user,
            .db_host = options.db_host,
            .db_port = options.db_port,
            .db_name = options.db_name,
        });
        run.step.dependOn(&install.step);
        return run;
    }

    pub const RegressTestOptions = struct {
        scripts: []const []const u8,

        root_dir: ?[]const u8 = null,

        db_user: ?[]const u8 = null,
        db_host: ?[]const u8 = null,
        db_port: ?u16 = null,
        db_name: ?[]const u8 = null,
        debug: bool = false,
        create_role: ?[]const u8 = null,
        load_extensions: ?[]const []const u8 = null,
    };

    /// Adds a pg_regress step for the project, defaulting the input/output/expected
    /// directories to the project root.
    pub fn addRegressTests(proj: Project, options: RegressTestOptions) *Step.Run {
        return proj.pgbuild.addRegress(.{
            .root_dir = options.root_dir orelse ".",
            .scripts = options.scripts,
            .db_user = options.db_user,
            .db_host = options.db_host,
            .db_port = options.db_port,
            .db_name = options.db_name,
            .debug = options.debug,
            .create_role = options.create_role,
            .load_extensions = options.load_extensions,
        });
    }

    pub const StepsOptions = struct {
        check: bool = true,
        schema: ?SchemaOptions = null,
        pg_regress: ?RegressTestOptions = null,
        unit: ?UnitTestOptions = null,
    };

    pub const Steps = struct {
        check: *Step,
        install: *Step,
        schema: ?*Step,
        pg_regress: *Step,
        unit: *Step,
    };

    /// Sets up the common build steps for an extension project in one call:
    ///
    ///   * `check`      - compiles the extension without linking or installing.
    ///   * `install`    - installs the extension library and directory (the default `zig build`).
    ///   * `pg_regress` - runs the pg_regress tests (only if `options.pg_regress` is set).
    ///   * `unit`       - runs the in-server unit tests (only if `options.unit` is set).
    pub fn addSteps(proj: Project, options: StepsOptions) Steps {
        const check = proj.build.step("check", "Check if project compiles");
        const install = proj.build.getInstallStep();
        const sql = proj.build.step("sql", "Generate the SQL extension script");
        const pg_regress = proj.build.step("pg_regress", "Run regression tests");
        const unit = proj.build.step("unit", "Run unit tests");

        install.dependOn(&proj.installExtensionLib().step);
        install.dependOn(&proj.installExtensionDir().step);

        var schema_step: ?*Step = null;
        if (options.schema) |schema_options| {
            const install_sql = proj.addSchema(schema_options);
            install.dependOn(&install_sql.step);
            sql.dependOn(&install_sql.step);
            schema_step = sql;
        }

        if (options.check) {
            const lib = proj.extensionLib();
            lib.linkage = null;
            check.dependOn(&lib.step);
        }

        if (options.pg_regress) |regress_options| {
            const regress = proj.addRegressTests(regress_options);
            regress.step.dependOn(install);
            pg_regress.dependOn(&regress.step);
        }

        if (options.unit) |unit_options| {
            const run = proj.addUnitTests(unit_options);
            unit.dependOn(&run.step);
        }

        return .{
            .check = check,
            .install = install,
            .schema = schema_step,
            .pg_regress = pg_regress,
            .unit = unit,
        };
    }
};

pub const DebugOptions = struct {
    pg_config: bool = false,
    extension_dir: bool = false,
    extension_lib: bool = false,
};

const Paths = struct {
    cwd: ?[]const u8 = null,
    bin_dir: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
    pg_home: ?[]const u8 = null,
    include_dir: ?[]const u8 = null,
    include_server_dir: ?[]const u8 = null,
    package_lib_dir: ?[]const u8 = null,
    shared_dir: ?[]const u8 = null,
    extension_dir: ?[]const u8 = null,
    pg_regress_path: ?[]const u8 = null,
    psql_path: ?[]const u8 = null,
};

pub const ExtensionVersion = struct {
    major: u32,
    minor: u32,
};

pub const InstallExtension = struct {
    lib: *Step.Compile,
    extension_dir: *Step.InstallDir,
    step: Step,

    pub const Options = struct {
        // plugin opts
        name: []const u8,
        version: ExtensionVersion,

        // paths
        root_dir: ?[]const u8 = null,
        root_source_file: ?LazyPath = null,
        extension_dir: ?[]const u8 = null,

        // shared library options
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
        single_threaded: bool = true,
        link_libc: bool = true,
        link_allow_shlib_undefined: bool = true,
    };

    pub fn create(b: *Build, options: Options) *InstallExtension {
        const root_dir = options.root_dir orelse
            b.std_build.pathJoin(&[_][]const u8{ "src/", options.name });

        const lib = b.addExtensionLib(.{
            .name = options.name,
            .version = options.version,
            .root_dir = root_dir,
            .root_source_file = options.root_source_file,
            .link_libc = options.link_libc,
        });

        const extension_dir = b.addInstallExtensionDir(
            resolvePath(b, root_dir, options.extension_dir, "extension") orelse @panic("root_dir or extension_dir"),
        );

        const install_ext = b.std_build.allocator.create(InstallExtension) catch @panic("OOM");
        install_ext.* = .{
            .lib = lib,
            .step = b.joinSteps("install_extension", .{
                &b.addInstallExtensionLibArtifact(lib, options.name).step,
                &extension_dir.step,
            }),
            .extension_dir = extension_dir,
        };
        return install_ext;
    }
};

pub const InitOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    debug: DebugOptions = .{},
};

pub fn create(std_build: *std.Build, options: InitOptions) *Build {
    const b = std_build.allocator.create(Build) catch @panic("OOM");
    b.* = .{
        .std_build = std_build,
        .paths = .{},
        .options = .{
            .target = options.target,
            .optimize = options.optimize,
        },
        .debug = options.debug,
        .modules = .{},
    };
    b.*.modules.builder = b;
    return b;
}

pub fn getIncludeDir(b: *Build) []const u8 {
    return b.getPath(&b.paths.include_dir, "--includedir", false);
}

pub fn getIncludeServerDir(b: *Build) []const u8 {
    return b.getPath(&b.paths.include_server_dir, "--includedir-server", false);
}

pub fn getPackageLibDir(b: *Build) []const u8 {
    return b.getPath(&b.paths.package_lib_dir, "--pkglibdir", false);
}

pub fn getLibDir(b: *Build) []const u8 {
    return b.getPath(&b.paths.lib_dir, "--libdir", false);
}
pub fn getSharedDir(b: *Build) []const u8 {
    return b.getPath(&b.paths.shared_dir, "--sharedir", true);
}

pub fn getBinDir(b: *Build) []const u8 {
    return b.getPath(&b.paths.bin_dir, "--bindir", false);
}

pub fn getExtensionDir(b: *Build) []const u8 {
    b.paths.extension_dir = b.paths.extension_dir orelse blk: {
        const shared = b.getSharedDir();
        break :blk b.std_build.pathJoin(&[_][]const u8{ shared, "extension" });
    };
    return b.paths.extension_dir.?;
}

pub fn getPGRegressPath(b: *Build) []const u8 {
    b.paths.pg_regress_path = b.paths.pg_regress_path orelse blk: {
        // `pg_config --pkglibdir` may point at a different installation root
        // than the one shipping the pgxs tooling (e.g. Nix splits the -dev
        // output out). `pg_config --pgxs` always points at the same tree as
        // pg_regress, i.e. <prefix>/lib/pgxs/src/makefiles/pgxs.mk, so derive
        // the tool path from it instead.
        const pgxs = b.runPGConfig("--pgxs");
        const pgxs_src = std.fs.path.dirname(std.fs.path.dirname(pgxs) orelse pgxs) orelse pgxs;
        break :blk b.std_build.pathJoin(&[_][]const u8{ pgxs_src, "test/regress/pg_regress" });
    };
    return b.paths.pg_regress_path.?;
}

pub fn getPsqlPath(b: *Build) []const u8 {
    b.paths.psql_path = b.paths.psql_path orelse blk: {
        const bin_dir = b.getBinDir();
        break :blk b.std_build.pathJoin(&[_][]const u8{ bin_dir, "psql" });
    };
    return b.paths.psql_path.?;
}

const ExtensionLibOptions = struct {
    name: []const u8,
    version: ExtensionVersion,
    root_dir: ?[]const u8 = null,
    root_source_file: ?LazyPath = null,
    link_libc: bool = true,
};

pub fn addExtensionLib(b: *Build, options: ExtensionLibOptions) *Step.Compile {
    const root_dir = options.root_dir orelse
        b.std_build.pathJoin(&[_][]const u8{ "src/", options.name });

    const lib_module = b.std_build.createModule(.{
        .root_source_file = b.resolveLazyPath(root_dir, options.root_source_file, "main.zig"),
        .target = b.options.target,
        .optimize = b.options.optimize,
        .link_libc = if (options.link_libc) true else null,
    });
    lib_module.addIncludePath(.{
        .cwd_relative = b.getIncludeServerDir(),
    });

    const lib = b.std_build.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .version = .{
            .major = options.version.major,
            .minor = options.version.minor,
            .patch = 0,
        },
        .root_module = lib_module,
    });
    lib.linker_allow_shlib_undefined = true;
    return lib;
}

pub fn installSharedLibExtension(b: *Build, artifact: *Step.Compile, ext_path: []const u8) void {
    b.std_build.getInstallStep().dependOn(&b.std_build.addInstallArtifact(artifact, .{
        .dest_dir = .{
            .override = .{
                .custom = b.std_build.pathJoin(&[_][]const u8{
                    b.getLibDir(),
                    ext_path,
                }),
            },
        },
    }).step);
}

pub fn addInstallExtension(b: *Build, options: InstallExtension.Options) *InstallExtension {
    return InstallExtension.create(b, options);
}

pub fn installExtension(b: *Build, options: InstallExtension.Options) *InstallExtension {
    const ext = b.addInstallExtension(options);
    b.std_build.getInstallStep().dependOn(&ext.step);
    return ext;
}

pub fn installExtensionLibArtifact(b: *Build, artifact: *Step.Compile, name: []const u8) *Step.InstallFile {
    const file_artifact = b.addInstallExtensionLibArtifact(artifact, name);
    b.std_build.getInstallStep().dependOn(&file_artifact.step);
    return file_artifact;
}

pub fn addInstallExtensionLibArtifact(b: *Build, artifact: *Step.Compile, name: []const u8) *Step.InstallFile {
    const lib_suffix = artifact.rootModuleTarget().dynamicLibSuffix();
    const plugin_name = std.fmt.allocPrint(b.std_build.allocator, "{s}{s}", .{ name, lib_suffix }) catch @panic("OOM");

    // TODO: resolve paths to ensures they are canonicalized.

    // Normally it is expected that the package libdir is a subdirectory of the pg_home.
    // Unfortunately in Nix the path can be reconfigured using an environment
    // variable, in which case the libdir is no subfolder of the Postgres
    // installation.
    //
    // If that is the case we only copy the shared library to the libdir if the
    // installation prefix is indeed the local postgres installation path.
    // Otherwise we force the shared library to be copied to the prefix path
    // directly (no sub folders).
    const pg_home = b.getPGHome();
    const package_lib_dir = b.getPackageLibDir();
    const is_deploy = std.mem.eql(u8, b.std_build.install_prefix, pg_home);
    const target_lib_dir = if (is_deploy or std.mem.startsWith(u8, package_lib_dir, pg_home))
        b.makeRelPath(package_lib_dir)
    else
        ".";

    const artifact_file = artifact.getEmittedBin();
    if (b.debug.extension_lib) {
        std.debug.print("pg_home: {s}\n", .{b.getPGHome()});
        std.debug.print("Package lib dir: {s}\n", .{package_lib_dir});

        std.debug.print("Configure step: install extension lib: {s} -> {s}/{s}\n", .{
            artifact_file.getDisplayName(),
            target_lib_dir,
            plugin_name,
        });
    }

    return b.std_build.addInstallFileWithDir(
        artifact_file,
        .{ .custom = target_lib_dir },
        plugin_name,
    );
}

pub fn addInstallExtensionDir(b: *Build, source_dir: []const u8) *Step.InstallDir {
    const source_dir_path = b.std_build.path(source_dir);
    const ext_dir = b.getExtensionDir();

    if (b.debug.extension_dir) {
        std.debug.print("Configure step: install extension dir: {s} -> {s}\n", .{ source_dir, ext_dir });
    }

    return b.std_build.addInstallDirectory(.{
        .source_dir = source_dir_path,
        .install_dir = .prefix,
        .install_subdir = ext_dir,
    });
}

pub fn installExtensionDir(b: *Build, source_dir: []const u8) void {
    b.std_build.getInstallStep().dependOn(&b.addInstallExtensionDir(source_dir).step);
}

pub const PGRegressOptions = struct {
    scripts: []const []const u8,
    root_dir: []const u8,

    db_user: ?[]const u8 = null,
    db_host: ?[]const u8 = null,
    db_port: ?u16 = null,
    db_name: ?[]const u8 = null,
    debug: bool = false,
    create_role: ?[]const u8 = null,
    load_extensions: ?[]const []const u8 = null,
};

pub fn addRegress(b: *Build, options: PGRegressOptions) *Step.Run {
    const pg_regress_tool = b.getPGRegressPath();
    const root_dir = options.root_dir;
    var runner = b.std_build.addSystemCommand(&[_][]const u8{
        pg_regress_tool,
        "--inputdir",
        root_dir,
        "--outputdir",
        root_dir,
        "--expecteddir",
        root_dir,
    });

    if (options.db_host) |db_host| {
        runner.addArg("--host");
        runner.addArg(db_host);
    }
    if (options.db_port) |db_port| {
        runner.addArg("--port");
        runner.addArg(std.fmt.allocPrint(b.std_build.allocator, "{d}", .{db_port}) catch @panic("OOM"));
    }
    if (options.db_user) |db_user| {
        runner.addArg("--user");
        runner.addArg(db_user);
    }
    if (options.db_name) |db_name| {
        runner.addArg("--dbname");
        runner.addArg(db_name);
    }
    if (options.create_role) |create_role| {
        runner.addArg("--create-role");
        runner.addArg(create_role);
    }
    if (options.debug) {
        runner.addArg("--debug");
    }
    if (options.load_extensions) |list| {
        for (list) |ext| {
            runner.addArg("--load-extension");
            runner.addArg(ext);
        }
    }

    for (options.scripts) |script| {
        runner.addArg(script);
    }
    return runner;
}

pub const RunTestsOptions = struct {
    name: []const u8,

    db_user: ?[]const u8 = null,
    db_host: ?[]const u8 = null,
    db_port: ?u16 = null,
    db_name: ?[]const u8 = null,
};

/// This runs the following SQL commands:
///
///  DROP FUNCTION IF EXISTS run_tests;
///  CREATE FUNCTION run_tests() RETURNS INTEGER AS '\''$libdir/{name}'\'' LANGUAGE C IMMUTABLE;
///  SELECT run_tests();
pub fn addRunTests(b: *Build, options: RunTestsOptions) *Step.Run {
    const sql = std.fmt.allocPrint(
        b.std_build.allocator,
        \\ DROP FUNCTION IF EXISTS run_tests;
        \\ CREATE FUNCTION run_tests() RETURNS INTEGER AS '$libdir/{s}' LANGUAGE C IMMUTABLE;
        \\ SELECT run_tests();
    ,
        .{options.name},
    ) catch @panic("OOM");
    const psql_exe = b.getPsqlPath();
    var runner = b.std_build.addSystemCommand(&[_][]const u8{
        psql_exe,
        "--no-psqlrc",
        "-v",
        "ON_ERROR_STOP=1",
        "-c",
        sql,
    });

    if (options.db_host) |db_host| {
        runner.addArg("--host");
        runner.addArg(db_host);
    }
    if (options.db_port) |db_port| {
        runner.addArg("--port");
        runner.addArg(std.fmt.allocPrint(b.std_build.allocator, "{d}", .{db_port}) catch @panic("OOM"));
    }
    if (options.db_user) |db_user| {
        runner.addArg("--user");
        runner.addArg(db_user);
    }
    if (options.db_name) |db_name| {
        runner.addArg("--dbname");
        runner.addArg(db_name);
    }
    return runner;
}

fn getPath(b: *Build, path: *?[]const u8, question: []const u8, relative: bool) []const u8 {
    path.* = path.* orelse blk: {
        var p = b.runPGConfig(question);
        if (relative) {
            p = b.makeRelPath(p);
        }
        break :blk p;
    };
    return path.*.?;
}

fn makeRelPath(b: *Build, path: []const u8) []const u8 {
    const cwd = b.getPGHome();
    return std.fs.path.relative(b.std_build.allocator, ".", null, cwd, path) catch @panic("failed to make relative path");
}

pub fn runPGConfig(b: *Build, question: []const u8) []const u8 {
    const argv = [_][]const u8{
        findPGConfig(b),
        question,
    };

    if (b.debug.pg_config) {
        std.debug.print("Running pg_config: {s} {s}\n", .{ argv[0], argv[1] });
    }

    // Build.run spawns the child and fails the build with a readable
    // message if pg_config is missing or exits non-zero.
    const path = trimWhitespace(b.std_build.run(&argv));
    if (path.len == 0) {
        @panic("pg_config failed");
    }

    if (b.debug.pg_config) {
        std.debug.print("pg_config returned: {s}\n", .{path});
    }
    return path;
}

pub fn getPGHome(b: *Build) []const u8 {
    b.paths.pg_home = b.paths.pg_home orelse blk: {
        const bindir = b.getBinDir();
        break :blk std.fs.path.dirname(bindir);
    };
    return b.paths.pg_home.?;
}

fn findPGConfig(b: *Build) []const u8 {
    return getenvOr(b, "PG_CONFIG", "pg_config");
}

fn getenvOr(b: *Build, name: []const u8, default: []const u8) []const u8 {
    return b.std_build.graph.environ_map.get(name) orelse default;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and std.ascii.isWhitespace(s[start])) : (start += 1) {}

    var end: usize = s.len;
    while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}

    return s[start..end];
}

fn resolveLazyPath(b: *Build, root_dir: []const u8, p: ?LazyPath, comptime default: []const u8) ?LazyPath {
    if (p) |configured_path| {
        return configured_path;
    }
    if (resolvePath(b, root_dir, null, default)) |path| {
        return .{
            .cwd_relative = path,
        };
    }
    return null;
}

fn resolvePath(b: *Build, root_dir: []const u8, p: ?[]const u8, default: []const u8) ?[]const u8 {
    if (p) |configured_path| {
        return configured_path;
    }
    return b.std_build.pathJoin(&[_][]const u8{ root_dir, default });
}

inline fn joinSteps(b: *Build, name: []const u8, steps: anytype) Step {
    var step = Step.init(.{
        .id = .custom,
        .name = name,
        .owner = b.std_build,
    });
    inline for (steps) |s| {
        step.dependOn(s);
    }
    return step;
}
