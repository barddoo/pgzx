---
title: Function manager
---

Register Zig functions so they can be called from SQL with [PG_FUNCTION_V1][docs_PG_FUNCTION_V1]:

```zig
comptime {
    pgzx.PG_FUNCTION_V1("my_function", myFunction);
}
```

Parameters are received from Postgres serialized, and pgzx deserializes them into Zig types automatically.

[docs_PG_FUNCTION_V1]: /api/#pgzx.PG_FUNCTION_V1
