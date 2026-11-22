---
title: pgzx internals
---

How [`src/pgzx/build.zig`](https://github.com/barddoo/pgzx/blob/main/src/pgzx/build.zig)
implements the steps above, and why the SQL generator forces the three-file
split.

## 1. Two build scripts

There are two distinct `build.zig` files:

- **`/build.zig`**: builds the pgzx library and its own test extension. It
  defines the `pgzx` module, translates the Postgres headers, generates node
  tags, builds docs, and runs the in-server pgzx tests.
- **`/src/pgzx/build.zig`**: the reusable *build helper API* (`Build`,
  `Project`, `InstallExtension`, …) that extensions import as
  `@import("pgzx").Build`.

### Root build script

```zig
pub const Build = @import("src/pgzx/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var pgbuild = Build.create(b, .{ .target = target, .optimize = optimize });
    // ...
}
```

It then:

1. Creates the `pgzx_pgsys` module by running `translate-c` over
   `src/pgzx/c/include/headers.h`, adding the Postgres `server`/`include` paths,
   the shim headers, the host OpenSSL/Kerberos include paths, and `PGZX_C_INCLUDE_DIRS`
   from the environment. It compiles `src/pgzx/c/libpqsrv.c` and links `libpq`.
2. Runs `tools/gennodetags/main.zig` to generate `nodetags.zig` (a codegen
   input for `src/pgzx/node.zig`).
3. Creates the `pgzx` module rooted at `src/pgzx.zig` with imports
   `pgzx_pgsys` and the anonymous `gen_node_tags` module.
4. Builds docs, pure tests, the `pgzx_unit` test extension, and the unit-test
   runner.

The `Project.init` helper is only used by extensions; the pgzx repo itself wires
its steps manually.

## 2. `Build`: the low-level helper

`Build` (`src/pgzx/build.zig`) is created with `Build.create(owner, .{ target, optimize, debug })`.
Responsibilities:

- **Locate PostgreSQL paths** lazily via `pg_config` (`runPGConfig`), with
  caching in `Build.paths`:
  `getIncludeDir`, `getIncludeServerDir`, `getLibDir`, `getPackageLibDir`,
  `getSharedDir`, `getBinDir`, `getExtensionDir`, `getPGHome`,
  `getPGRegressPath`, `getPsqlPath`.
  `PG_CONFIG` can override the binary; otherwise `pg_config` from `PATH` is used.
  Paths that must be relative to the install prefix (sharedir) are converted
  with `makeRelPath`.
- **Provide modules** to extensions: `modules.pgzx()` and `modules.pgsys()`,
  resolved through `std_build.dependency("pgzx", options).module(name)`.
- **Create extension libraries**: `addExtensionLib`.
- **Install artifacts**: `addInstallExtension`, `installExtension`,
  `addInstallExtensionLibArtifact`, `addInstallExtensionDir`.
- **Run tests**: `addRegress`, `addRunTests`.

### `addExtensionLib`

Creates a `dynamic` library:

```zig
pub fn addExtensionLib(b: *Build, options: ExtensionLibOptions) *Step.Compile {
    const lib_module = b.std_build.createModule(.{
        .root_source_file = resolveLazyPath(root_dir, options.root_source_file, "main.zig"),
        .target = b.options.target,
        .optimize = b.options.optimize,
        .link_libc = true,
    });
    lib_module.addIncludePath(.{ .cwd_relative = b.getIncludeServerDir() });

    const lib = b.std_build.addLibrary(.{
        .name = options.name,
        .linkage = .dynamic,
        .version = .{ .major, .minor, .patch = 0 },
        .root_module = lib_module,
    });
    lib.linker_allow_shlib_undefined = true; // server symbols resolved at load
    return lib;
}
```

`linker_allow_shlib_undefined = true` is what lets the `.so` reference
`palloc`, `errcode`, and friends; the PostgreSQL backend resolves them when it
loads the library.

### Installing the library

`addInstallExtensionLibArtifact` computes the platform suffix (`.so`, `.dylib`)
and decides where to put the result. Normally the package libdir
(`pg_config --pkglibdir`) is inside `$PG_HOME`, so the artifact is installed at
the relative path under the prefix. For split installations (common with
distro `-dev` packages, where `--pkglibdir` may point elsewhere), it falls
back to installing directly at the prefix root. This logic protects against
deploying into the wrong tree when the install prefix is not `$PG_HOME`.

## 3. `Project`: the extension-facing helper

`Project` bundles the configuration and provides convenience methods:

- `init` validates/defaults the config, creates `build_options` and
  `test_build_options` (the `testfn` gate), and loads the `pgzx` module.
- `createLib(name, options)` builds an extension library and calls
  `configureLib`, which attaches:
  - the `pgzx` import,
  - the `build_options` module and every module added via `addOptions`,
  - accumulated include paths, library paths, and C source files
    (`addIncludePath`, `addLibraryPath`, `addCSourceFiles`).
- `extensionLib` / `installExtensionLib` / `installExtensionDir` wrap the
  low-level install functions with the project's name/version.
- `addUnitTests` builds `<name>_unit` with `testfn = true` and returns the
  `SELECT run_tests()` run step.
- `addRegressTests` forwards to `Build.addRegress`.
- `addSchema` is the SQL generator (next section).
- `addSteps` assembles the public steps.

`addSteps` produces:

```
zig build
└── install (default)
    ├── install extension library         -> $prefix/lib/<name>.so
    ├── install extension directory       -> $prefix/share/postgresql/extension/*
    └── install generated SQL (optional)  -> $prefix/share/postgresql/extension/<name>--<ver>.sql

zig build check      -> compile the extension module only
zig build sql        -> install generated SQL only
zig build unit       -> <name>_unit + SELECT run_tests()
zig build pg_regress -> pg_regress over the configured scripts
```

## 4. SQL generation internals (`Project.addSchema`)

`addSchema(options: SchemaOptions)`:

1. **Resolve the source.** `source` defaults to `<root_dir>/schema.zig`.
2. **Create the schema module.** A `std.Build.Module` rooted at that file,
   built with `.optimize = .ReleaseSmall, .strip = true`, wired with the `pgzx`
   import, `build_options`, extra options, and include paths. The small/optimized
   build is essential (see §7).
3. **Synthesize the generator.** `b.addWriteFiles()` creates
   `pgzx_generate_sql.zig`:

   ```zig
   const std = @import("std");
   const pgzx = @import("pgzx");
   const schema = @import("schema");

   pub fn main(init: std.process.Init) !void {
       var buffer: [64 * 1024]u8 = undefined;
       var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
       const stdout = &stdout_writer.interface;
       try pgzx.ddl.render(stdout, schema.pgzx_sql);
       try stdout.flush();
   }
   ```

   The declaration name is substituted from `options.declaration` (default
   `pgzx_sql`). This uses Zig 0.16's `std.process.Init`/`std.Io` API.

4. **Build the executable.** A module importing `pgzx` and the `schema` module,
   as an `addExecutable`, also `.ReleaseSmall`/`.strip`.
5. **Capture and install.** `b.addRunArtifact(exe).captureStdOut(.{ .basename = file_name })`
   yields a `LazyPath`; `addInstallFileWithDir` installs it at
   `$prefix/<getExtensionDir()>/<file_name>`. The default file name is
   `<name>--<major>.<minor>.sql`.

### The renderer

`src/pgzx/ddl.zig`:

- `Function(decl)` normalizes an entry to a type with all fields present,
  using `@hasField` and comptime ternaries so that omitted fields fall back to
  defaults without being semantically analyzed.
- `render(writer, schema)` emits the optional `sql` preamble and then loops
  `inline for (schema.functions)`.
- `renderFunction` derives argument types from
  `@typeInfo(fn).@"fn".params`, skipping `pg.FunctionCallInfo`, unless `args`
  is set. Return type goes through `meta.fnReturnType` (unwrapping
  `error_union`) and `datum.sqlType`.
- Type→SQL mapping is `src/pgzx/datum.zig:sqlType`, which reads the `sql_name`
  field attached to each `Conv` converter. `SimpleConv` takes the SQL name as a
  required comptime parameter, and `Conv`/`ConvNoFail`/`OptConv` propagate it,
  so optionals (`?T`) inherit `T`'s mapping.

The renderer is intentionally extensible: adding aggregates, triggers, or types
means adding another `@hasField(schema, "...")` branch and an emitter, without
changing the driver.

## 5. In-server unit tests

- `Project.addUnitTests` builds a second library named `<name>_unit` with
  `build_options.testfn = true`.
- `main.zig` calls
  `pgzx.testing.registerTests(@import("build_options").testfn, .{...})`, so the
  production library contains no test registration.
- `Build.addRunTests` runs (via `psql`):

  ```sql
  DROP FUNCTION IF EXISTS run_tests;
  CREATE FUNCTION run_tests() RETURNS INTEGER AS '$libdir/<name>_unit' LANGUAGE C IMMUTABLE;
  SELECT run_tests();
  ```

`run_tests` is itself a v1 fmgr function registered by
`src/testing.zig`; it walks every registered suite, runs functions named
`test*`, and reports the count.

## 6. `pg_regress`

`Build.addRegress` locates `pg_regress` from `pg_config --pgxs` (deriving the
tool path from the pgxs makefile location, which keeps `pg_regress` consistent
with the same PostgreSQL tree as the headers even when split packages are
installed). It runs:

```
pg_regress --inputdir <root> --outputdir <root> --expecteddir <root> \
           [--host ..] [--port ..] [--user ..] [--dbname ..] [--create-role ..] \
           [--load-extension ..] <scripts...>
```

and the `pg_regress` build step depends on `install`, so the `.so`, the control
file, and the generated SQL are in place before the tests run.

## 7. The linking constraint (why the three-file split exists)

`PG_FUNCTION_V1("name", fn)` does two things: it exports `pg_finfo_<name>`, and
it `@export`s a generated C-ABI wrapper that calls `fn`. `@export` makes the
symbol a linker root, so the wrapper, and therefore `fn`'s body, is emitted
even in release builds. Those bodies call server functions such as `palloc`,
`errcode`, `CurrentMemoryContext`, `get_fn_expr_argtype`, … .

A shared library may reference those symbols (`linker_allow_shlib_undefined`).
An executable may not: the dynamic linker would have nothing to bind them to.
Because `addSchema` must run a generator executable, the generator's import
graph must not contain any `@export`ed function body.

Concretely, this fails to link (observed):

```
error: undefined symbol: pfree
error: undefined symbol: get_fn_expr_argtype
...
note: referenced by pgzx_generate_sql ... (hello_world_zig_datum)
```

Two things were tried before settling on the split:

- Debug builds fail with references from `.debug_info`; stripping removes that,
  but `@export` still emits `.text`.
- Zig's build API does not expose `--unresolved-symbols=ignore-all`/`-z undefs`
  (only the opposite, `-z defs`), so the linker cannot be told to tolerate the
  unresolved symbols.

The fix is architectural: the generator imports only `schema.zig` (plus the
`pgzx` library), never `main.zig`. Functions are referenced solely as comptime
values in `pgzx_sql`, so the `ReleaseSmall` + `strip` generator build dead-strips
their bodies and no server symbol is referenced at link time. The schema module
therefore *must not* call `PG_FUNCTION_V1`/`PG_EXPORT`, which is exactly the rule
documented for extension authors in [Part I](/build-system/).

## 8. Codegen inputs

- **`pgzx_pgsys`**: produced by `addTranslateC` over
  `src/pgzx/c/include/headers.h` with Postgres server headers, a PG15 `varatt.h`
  shim, and host SSL/Kerberos includes. This is the `pg`/`c` namespace used
  throughout pgzx and extensions.
- **`gen_node_tags`**: `tools/gennodetags/main.zig` parses Postgres node tag
  headers and emits a Zig enum/module used by `src/pgzx/node.zig`.

Both are created once in the root build script and threaded into the `pgzx`
module so every consumer sees the same generated code.

## 9. Extending the build

- **New library feature:** add a module under `src/pgzx/`, export it from
  `src/pgzx.zig`, and (if it has server tests) register its suite in
  `src/testing.zig`.
- **New schema object:** add an emitter to `src/pgzx/ddl.zig` and a branch in
  `render` keyed on a new top-level field in `pgzx_sql`.
- **New SQL type:** add a `sql_name` to the relevant converter in
  `src/pgzx/datum.zig`, or teach a custom type's `Conv` to expose `sql_name`.
- **New build step:** extend `Project.StepsOptions`/`addSteps` and wire the
  step with `b.step(...)`.

---
