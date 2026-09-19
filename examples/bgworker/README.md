bgworker
========

Demonstrates registering a Postgres background worker with pgzx.

`_PG_init` registers a static worker via `pgzx.bgworker.register`. Static
workers are launched by the postmaster on the next server start; the worker
logs a message and exits (with `restart_time = BGW_NEVER_RESTART`).

## Try it

1. Build and install, then create the extension:

   ```sh
   zig build -freference-trace -p $PG_HOME
   psql -U postgres -c 'CREATE EXTENSION bgworker'
   ```

2. Restart the server so the postmaster launches the worker, then check the
   server log for the message:

   ```
   pgzx bgworker example: worker started
   ```
