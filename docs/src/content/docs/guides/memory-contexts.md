---
title: Memory context allocators
---

Postgres uses a [memory context system](https://github.com/postgres/postgres/blob/master/src/backend/utils/mmgr/README): allocations belong to a context, and freeing a context frees everything in it at once. Contexts are hierarchical, so a child context is freed with its parent.

pgzx wraps contexts as Zig allocators. [createAllocSetContext][docs_createAllocSetContext] returns a [MemoryContextAllocator][docs_MemoryContextAllocator]:

```zig
var memctx = try pgzx.mem.createAllocSetContext("zig_context", .{ .parent = pg.CurrentMemoryContext });
const allocator = memctx.allocator();
```

`pg.CurrentMemoryContext` is the context of the running query, so memory allocated with `allocator` is freed when the query finishes. You can also register a callback for when a context is reset or deleted, to release resources tied to it:

```zig
try memctx.registerAllocResetCallback(
    queryDesc.*.estate.*.es_query_cxt,
    pgaudit_zig_MemoryContextCallback,
);
```

[docs_createAllocSetContext]: /api/#pgzx.pgzx.mem.createAllocSetContext
[docs_MemoryContextAllocator]: /api/#pgzx.pgzx.mem.MemoryContextAllocator
