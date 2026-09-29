# file_io - backend-safe file I/O with pgzx

This example shows how a Zig extension reads and writes files the way a
PostgreSQL backend is supposed to: through the **virtual file descriptor**
layer in `src/backend/storage/file/fd.c`, exposed as `pgzx.fd`.

Do not use `std.fs` or `open(2)` directly in a backend. The VFD layer is what

* keeps the process under `max_files_per_process`,
* shares descriptors through the LRU when the OS limit is reached,
* removes temporary files at transaction end (including on abort),
* reports I/O failures as ordinary Postgres errors.

The example also demonstrates PG18's **asynchronous I/O** (`pgzx.aio`), which
can issue reads on a VFD through an `PgAioHandle` and an I/O worker process.

## Functions

```sql
-- Round-trip data through a transaction-scoped temporary file.
SELECT file_io_roundtrip('hello, world');
-- Truncate the temporary file to `keep` bytes and return what remains.
SELECT file_io_truncate('0123456789', 4);
```

`file_io_roundtrip`:

```zig
var file = try pgzx.fd.openTemp(false);
defer file.close();

_ = try file.writeAll(data, 0);
try file.sync();

const out = try pgzx.mem.PGCurrentContextAllocator.alloc(u8, data.len);
const n = try file.readAll(out, 0);
return out;
```

## Asynchronous reads (PostgreSQL 18+)

`pgzx.aio` wraps the PG18 AIO subsystem. `AioHandle.acquire()` takes a handle
from the current resource owner, `File.startReadV()` binds it to a VFD read,
and `handle.wait()` blocks for completion:

```zig
var handle = try pgzx.aio.AioHandle.acquire();
defer handle.release();

try file.startReadV(&handle, &.{out}, 0, .local);
if (try handle.wait() != .ok) { ... }
return out;
```

Points worth noting:

* `locality` must be honest. With the default `io_method = worker`, an I/O may
  run in a different process; a backend-local buffer (palloc, local buffer,
  stack) can only be read into synchronously, so declare `.local`. Shared
  memory can use `.shared`.
* After a successful start the handle is *consumed* — wait, then release. The
  wrapper takes the wait reference before starting for exactly this reason.
* Only **reads** are asynchronous through the VFD API (`FileStartReadV`);
  `fd.File` writes stay synchronous.

The async path is only compiled/run on PG18+ (`pgzx.aio.enabled`); on older
servers the unit test skips it and `pgzx.fd` remains fully usable.

## Running

From the pgzx development shell (see the top-level README):

```sh
cd examples/file_io
zig build -freference-trace -p "$PG_HOME"   # build and install
zig build -p "$PG_HOME" unit                # in-server unit tests
zig build pg_regress                        # SQL regression tests
```

Or run everything the way CI does:

```sh
./ci/run.sh
```
