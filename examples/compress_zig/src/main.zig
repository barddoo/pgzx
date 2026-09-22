// Compress Zig: on-disk columnar compression example.
//
// The function implementations live in functions.zig so the SQL schema
// generator (schema.zig) can introspect them without linking the server. This
// file registers and exports them.

const pgzx = @import("pgzx");
const functions = @import("functions.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();
}

comptime {
    pgzx.PG_FUNCTION_V1("compress_table", functions.compress_table);
    pgzx.PG_FUNCTION_V1("decompress_table", functions.decompress_table);
    pgzx.PG_FUNCTION_V1("batch_count", functions.batch_count);
    pgzx.PG_FUNCTION_V1("compressed_size", functions.compressed_size);
}
