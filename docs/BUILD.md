# The pgzx build system, in depth

This document explains how a PostgreSQL extension is built with pgzx, from two
points of view:

1. **Extension creator** — how to configure `build.zig`, describe your SQL
   schema, and run the build/test steps.
2. **pgzx internals** — how `src/pgzx/build.zig` implements those steps, how the
   SQL generator is wired up, and how the pieces fit together.

It complements [HACKING.md](../HACKING.md), which covers the development shell and
a local PostgreSQL install. Where this document talks about `$PG_HOME`, that is
the relocated PostgreSQL installation from HACKING.md.

---

# Part I — For the extension creator

## 1. The dependency mechanism

An extension is a normal Zig package whose `build.zig.zon` depends on pgzx by
path, URL, or tarball:

```zig
// build.zig.zon
.dependencies = .{
    .pgzx = .{ .path = "./../.." },
},
```

`build.zig` imports the **dependency's build script**, not the runtime library:

```zig
const std = @import("std");
const PGBuild = @import("pgzx").Build;

pub fn build(b: *std.Build) void {
    const proj = PGBuild.Project.init(b, .{
        .name = "my_extension",
        .version = .{ .major = 0, .minor = 1 },
        .root_dir = "src/",
        .root_source_file = "src/main.zig",
    });

    _ = proj.addSteps(.{
        .schema = .{},
        .pg_regress = .{
            .db_user = "postgres",
            .db_port = 5432,
            .scripts = &[_][]const u8{"my_extension_test"},
        },
        .unit = .{
            .db_user = "postgres",
            .db_port = 5432,
        },
    });
}
```

`@import("pgzx")` in a build script resolves to pgzx's root `build.zig`, which
re-exports the helper namespace:

```zig
// pgzx/build.zig
pub const Build = @import("src/pgzx/build.zig");
```

At runtime, extension code uses a *different* import with the same name,
`@import("pgzx")`, which resolves to the library entry point `src/pgzx.zig`.
The two live in separate build contexts and never conflict.

`Project.init` stores your name, version, `root_dir`, root source file, and
extension directory. It defaults `root_source_file` to `<root_dir>/<name>.zig`
and `extension_dir` (the *source* directory holding `.control`/`.sql` files) to
`./extension/`. It also creates two options modules that gate the in-server test
entry point: `build_options.testfn = false` for the production library and
`build_options.testfn = true` for the dedicated unit-test library.

## 2. Recommended source layout: the three-file split

Zig cannot introspect a function's parameter *names*, and it has no attribute
macros, so pgzx uses an explicit comptime declaration for SQL metadata. That
declaration must be reachable by a build-time generator — and the generator
cannot link against the Postgres server. As a result, the recommended layout is:

```
src/
  functions.zig   pure function definitions; no exports, no registration
  schema.zig      the pgzx_sql declaration; imports functions.zig
  main.zig        PG_MODULE_MAGIC, PG_FUNCTION_V1, PG_EXPORT, raw C exports
```

Why the split matters (details in Part II, §7): `PG_FUNCTION_V1` and `@export`
force the compiler to emit a function's body, which references Postgres backend
symbols. The SQL generator is linked as a standalone executable and has no way
to resolve those symbols. By keeping `schema.zig` (and `functions.zig`) free of
registration, the generator can import the signatures as *compile-time metadata
only*; the optimized generator build discards the bodies.

- `functions.zig` holds the actual SQL-visible functions. A plain `fn` here is
  enough; it does not need to be `export`.
- `schema.zig` names the SQL objects and points at the functions.
- `main.zig` is what PostgreSQL loads. It declares the module magic, registers
  each function with the fmgr wrapper, and re-exports raw C-convention
  functions. This file is never imported by the generator.

If your extension has no SQL functions (for example a pure background-worker
extension), you do not need `schema.zig` or the `.schema` build option at all.

## 3. Describing the schema

`src/schema.zig` exports a comptime value, conventionally named `pgzx_sql`:

```zig
const functions = @import("functions.zig");

pub const pgzx_sql = .{
    // Raw SQL emitted before the generated statements. Use it for anything the
    // generator does not model yet, or that must exist first (shell types,
    // schemas, ...).
    .sql = "CREATE SCHEMA IF NOT EXISTS my_extension;",

    .functions = .{
        .{ .name = "char_count_zig", .func = functions.char_count_zig },
        .{
            .name = "char_count_ci",
            .func = functions.char_count_ci,
            .volatility = .immutable,
            .strict = true,
            .parallel = .safe,
            .comment = "Count non-overlapping occurrences of a character.",
        },
    },

    // Raw SQL emitted after the generated statements, for objects that depend
    // on the functions (operators, operator classes, casts, ...).
    .post_sql = "GRANT EXECUTE ON FUNCTION char_count_zig(text, text) TO PUBLIC;",
};
```

The three sections are emitted in order: `.sql`, then the generated functions,
then `.post_sql`. That ordering is what allows a type whose shell is declared
first, whose I/O functions are generated, and whose operators/casts are added
last — see `examples/rational`.

Only `name` and `func` are required. Every other field has a default:

| Field        | Type                     | Default            | Meaning |
| ------------ | ------------------------ | ------------------ | ------- |
| `name`       | `[]const u8`             | —                  | SQL function name. |
| `func`       | a function               | —                  | The Zig implementation. |
| `volatility` | `pgzx.ddl.Volatility`    | `.@"volatile"`     | `VOLATILE` / `STABLE` / `IMMUTABLE`. |
| `strict`     | `bool`                   | `false`            | Emit `STRICT` (returns NULL on NULL input). |
| `parallel`   | `?pgzx.ddl.Parallel`     | `null`             | `UNSAFE` / `RESTRICTED` / `SAFE`; omitted when null. |
| `args`       | `?[]const []const u8`    | `null`             | Override argument SQL types. |
| `returns`    | `?[]const u8`            | `null`             | Override the return SQL type. |
| `symbol`     | `?[]const u8`            | `null`             | C symbol when it differs from the SQL name (emits `AS 'MODULE_PATHNAME', 'symbol'`). |
| `comment`    | `?[]const u8`            | `null`             | Emit `COMMENT ON FUNCTION`. |

`pgzx.ddl.Volatility` and `pgzx.ddl.Parallel` are exported by the library so the
schema file can import them through `pgzx`:

```zig
const pgzx = @import("pgzx");
// .volatility = pgzx.ddl.Volatility.immutable
```

### Derived types

Unless overridden, argument and return types are derived from the Zig signature
through the same converters that marshal datums at runtime. A `pg.FunctionCallInfo`
parameter is treated as the fmgr context and is not emitted as a SQL argument.

Current built-in mappings:

| Zig type | SQL type |
| --- | --- |
| `void` | `void` |
| `bool` | `boolean` |
| `i8`, `i16`, `u8` | `smallint` |
| `i32`, `u16` | `integer` |
| `i64`, `u32`, `u64` | `bigint` |
| `f32` | `real` |
| `f64` | `double precision` |
| `[]const u8`, `[:0]const u8` | `text` |
| `?T` | same as `T` |

Because the mapping lives on the type converters (`Conv` in
`src/pgzx/datum.zig`), a type without a direct SQL representation raises a
compile error at generation time, which is much better than emitting a broken
script.

### Overrides

Use `args`/`returns` when the Zig type has no direct SQL mapping — a raw
`pg.Datum`, a C-convention wrapper, or a type you want to name differently:

```zig
// fn hello_world_c(fcinfo: pg.FunctionCallInfo) pg.Datum
.{ .name = "hello_world_c", .func = functions.hello_world_c,
   .args = &.{"text"}, .returns = "text" },
```

The generated statement is always:

```sql
CREATE FUNCTION name(argtypes) RETURNS rettype
AS 'MODULE_PATHNAME'
LANGUAGE C [IMMUTABLE|STABLE] [STRICT] [PARALLEL ...];
```

Note that argument names are not generated (`text`, not `name text`): Zig 0.16
does not expose parameter names through `@typeInfo`. That is valid SQL and does
not affect calls. If you need names, put the full spelling in `args`
(`&.{"name text"}`).

## 4. Build steps

`addSteps` registers a consistent set:

| Step | Command | What it does |
| --- | --- | --- |
| install | `zig build` | Builds the shared library, installs the `.control`/static SQL directory, and installs the generated versioned SQL script. |
| check | `zig build check` | Compiles the extension as an object without linking/installing. Fast feedback. |
| sql | `zig build sql` | Generates and installs only the versioned SQL script. |
| unit | `zig build unit` | Builds a `<name>_unit` library with `testfn = true`, installs it, runs `SELECT run_tests()`. |
| pg_regress | `zig build pg_regress` | Runs the SQL regression tests via the PostgreSQL `pg_regress` tool. |

Install location:

```sh
zig build                     # everything lands in ./zig-out
zig build -p "$PG_HOME"       # installs into the running PostgreSQL:
                              #   $PG_HOME/lib/<name>.so
                              #   $PG_HOME/share/postgresql/extension/*
```

The `sql` step exists so you can regenerate and inspect the script without a
full build:

```sh
zig build sql
cat zig-out/share/postgresql/extension/my_extension--0.1.sql
```

## 5. The extension directory and loading

The source `extension/` directory is installed verbatim into
`$PG_HOME/share/postgresql/extension`. It must contain a control file:

```ini
# extension/my_extension.control
comment = 'my extension'
default_version = '0.1'
module_pathname = '$libdir/my_extension'
relocatable = true
```

The generated script uses the token `MODULE_PATHNAME`, which PostgreSQL
substitutes using `module_pathname` from the control file when the extension is
created. The generated file is named `<name>--<major>.<minor>.sql`, matching
`default_version` in the control file.

```sh
psql -U postgres -c 'CREATE EXTENSION my_extension;'
```

## 6. Testing

- **In-server unit tests.** Put suites in `functions.zig` and register them from
  `main.zig`:

  ```zig
  comptime {
      pgzx.testing.registerTests(@import("build_options").testfn, .{
          functions.Testsuite1,
          functions.Testsuite2,
      });
  }
  ```

  Any function whose name starts with `test` is a test. Run with
  `zig build unit -p "$PG_HOME"`.

- **`pg_regress`.** Provide `sql/<script>.sql` and `expected/<script>.out` and
  list the scripts in `.pg_regress`. Run with
  `zig build pg_regress -p "$PG_HOME"`.

- **Pure Zig tests.** Not part of the extension build; used inside pgzx itself
  for modules that do not need a server.

Complete working examples:

- `examples/char_count_zig` — minimal, one function.
- `examples/sqlfns` — every registration style, including raw C exports and
  `PG_EXPORT`.
- `examples/rational` — a base type; shows `.post_sql` (embedded
  `catalog.sql`) and `.symbol` (SQL name `abs`, C symbol `rational_abs`), and
  the ordering trick of a shell type followed by generated I/O functions.

## 7. Pitfalls

- **Do not put `PG_FUNCTION_V1`/`PG_EXPORT` in `schema.zig`.** The generator
  will fail to link with `undefined symbol: palloc`-style errors. Keep
  registration in `main.zig`.
- **Point `.schema.source` at the right file.** The default is
  `<root_dir>/schema.zig`. If you name it differently, pass
  `.schema = .{ .source = "src/my_schema.zig" }`.
- **Keep the control file's `default_version` in sync with `.version`** in
  `Project.init`, or PostgreSQL will look for a SQL file that does not exist.
- **A missing SQL type mapping is a compile error**, not silent output. Add the
  type to `datum.zig` or use `args`/`returns`.
- **Regenerate on every build.** The SQL step runs as part of `zig build`; do
  not hand-edit the generated file (it is overwritten).

---

# Part II — Inside pgzx

## 1. Two build scripts

There are two distinct `build.zig` files:

- **`/build.zig`** — builds the pgzx library and its own test extension. It
  defines the `pgzx` module, translates the Postgres headers, generates node
  tags, builds docs, and runs the in-server pgzx tests.
- **`/src/pgzx/build.zig`** — the reusable *build helper API* (`Build`,
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
the relative path under the prefix. For split installations (notably Nix, where
`--pkglibdir` may point elsewhere), it falls back to installing directly at the
prefix root. This logic protects against deploying into the wrong tree when the
install prefix is not `$PG_HOME`.

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
with the same PostgreSQL tree as the headers even when Nix splits outputs). It
runs:

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
symbol a linker root, so the wrapper — and therefore `fn`'s body — is emitted
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
documented for extension authors in Part I, §2/§7.

## 8. Codegen inputs

- **`pgzx_pgsys`** — produced by `addTranslateC` over
  `src/pgzx/c/include/headers.h` with Postgres server headers, a PG15 `varatt.h`
  shim, and host SSL/Kerberos includes. This is the `pg`/`c` namespace used
  throughout pgzx and extensions.
- **`gen_node_tags`** — `tools/gennodetags/main.zig` parses Postgres node tag
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

## Appendix: complete minimal example

`examples/char_count_zig` in full.

```
examples/char_count_zig/
  build.zig
  build.zig.zon
  extension/char_count_zig.control
  src/functions.zig
  src/schema.zig
  src/main.zig
  sql/char_count_test.sql
  expected/char_count_test.out
```

`build.zig`:

```zig
const std = @import("std");
const PGBuild = @import("pgzx").Build;

pub fn build(b: *std.Build) void {
    const proj = PGBuild.Project.init(b, .{
        .name = "char_count_zig",
        .version = .{ .major = 0, .minor = 1 },
        .root_dir = "src/",
        .root_source_file = "src/main.zig",
    });

    _ = proj.addSteps(.{
        .schema = .{},
        .pg_regress = .{
            .db_user = "postgres",
            .db_port = 5432,
            .scripts = &[_][]const u8{"char_count_test"},
        },
        .unit = .{
            .db_user = "postgres",
            .db_port = 5432,
        },
    });
}
```

`src/schema.zig`:

```zig
const functions = @import("functions.zig");

pub const pgzx_sql = .{
    .functions = .{
        .{ .name = "char_count_zig", .func = functions.char_count_zig },
    },
};
```

`src/main.zig`:

```zig
const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();
    pgzx.PG_FUNCTION_V1("char_count_zig", functions.char_count_zig);
}

comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{
        functions.Testsuite1,
        functions.Testsuite2,
    });
}
```

Generated script (`zig build sql`):

```sql
CREATE FUNCTION char_count_zig(text, text) RETURNS bigint
AS 'MODULE_PATHNAME'
LANGUAGE C;
```
