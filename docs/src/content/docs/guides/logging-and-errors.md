---
title: Logging and error handling
---

Postgres [error reporting functions](https://www.postgresql.org/docs/current/error-message-reporting.html) provide log levels, formatting, and errors that can be thrown and caught like exceptions. pgzx wraps them for Zig.

Simple logging uses [Log][docs_Log], [Info][docs_Info], [Notice][docs_Notice] or [Warning][docs_Warning]:

```zig
elog.Info(@src(), "input_text: {s}\n", .{input_text});
```

The `@src()` built-in records the file location in the error report.

To report errors, use [Error][docs_Error] (returns a Zig error) or [ErrorThrow][docs_ErrorThrow] (throws a Postgres error report):

```zig
if (target_char.len > 1) {
    return elog.Error(@src(), "Target char is more than one byte", .{});
}
```

The module also exposes the C-style API (`ereport`, `errcode`, `errmsg`, ...).

Postgres handles errors with `longjmp`, which can skip Zig `defer`/`errdefer` cleanup. pgzx provides a Zig alternative to `PG_TRY`:

```zig
var errctx = pgzx.err.Context.init();
defer errctx.deinit();
if (errctx.pg_try()) {
    // Zig code that calls Postgres C functions.
} else {
    return errctx.errorValue();
}
```

This catches errors raised by Postgres functions and returns them as Zig errors, so all `defer`/`errdefer` in the callers run. The [wrap][docs_wrap] helper packages this pattern:

```zig
try pgzx.err.wrap(myFunction, .{arg1, arg2});
```

See [pgzx.err.Context][docs_Context] for details.

[docs_Log]: /api/#pgzx.pgzx.elog.Log
[docs_Info]: /api/#pgzx.pgzx.elog.Info
[docs_Notice]: /api/#pgzx.pgzx.elog.Notice
[docs_Warning]: /api/#pgzx.pgzx.elog.Warning
[docs_Error]: /api/#pgzx.pgzx.elog.Error
[docs_ErrorThrow]: /api/#pgzx.pgzx.elog.ErrorThrow
[docs_Context]: /api/#pgzx.pgzx.err.Context
[docs_wrap]: /api/#pgzx.pgzx.err.wrap
