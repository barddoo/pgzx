---
title: Testing your extension
---

pgzx provides `pg_regress` tests and in-server unit tests, set up through the `PGBuild.Project` build helper:

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

`addSteps` creates the `check`, `install`, `pg_regress` (when `.pg_regress` is set) and `unit` (when `.unit` is set) build steps, and defines the `build_options` module that gates `testfn`.

[pg_regress tests](https://www.postgresql.org/docs/current/regress.html) work like they do for C extensions: inputs go in `sql/`, expected outputs in `expected/`, and run with:

```sh
zig build pg_regress
```

Unit tests run inside Postgres, so they compile in the same environment as the tested code and can call Postgres APIs. Each function whose name starts with `test` in a registered test suite is a unit test:

```zig
comptime {
    pgzx.testing.registerTests(@import("build_options").testfn, .{Tests});
}
```

`registerTests` may only be called once per extension; pass multiple suites in the array. Run the tests with:

```sh
zig build unit -p $PG_HOME
```

This builds a dedicated `{name}_unit` library with `testfn = true`, deploys it, and calls `SELECT run_tests();`. The separate library name means the test build never collides with the production extension.
