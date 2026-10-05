const pgzx = @import("pgzx.zig");
const varatt = @import("pgzx/varatt.zig");

comptime {
    pgzx.PG_MODULE_MAGIC();

    pgzx.testing.registerTests(
        @import("build_options").testfn,
        .{
            pgzx.collections.list.TestSuite_PointerList,
            pgzx.collections.vlist.TestSuite_ValueList,
            pgzx.collections.slist.TestSuite_SList,
            pgzx.collections.dlist.TestSuite_DList,
            pgzx.collections.htab.TestSuite_HTab,

            pgzx.aio.TestSuite_Aio,
            pgzx.atomics.TestSuite_Atomics,
            pgzx.datum.TestSuite_Datum,
            pgzx.ddl.TestSuite_Ddl,
            pgzx.err.TestSuite_Err,
            pgzx.elog.TestSuite_Elog,
            pgzx.fd.TestSuite_Fd,
            pgzx.intr.TestSuite_Interrupts,
            pgzx.itemptr.TestSuite_Itemptr,
            pgzx.lwlock.TestSuite_LWLock,
            pgzx.meta.TestSuite_Meta,
            pgzx.mem.TestSuite_Mem,
            pgzx.node.TestSuite_Node,
            pgzx.pgbox.TestSuite_PgBox,
            pgzx.shmem.TestSuite_Shmem,
            pgzx.spi.TestSuite_Spi,
            pgzx.spinlock.TestSuite_SpinLock,
            pgzx.str.TestSuite_Str,
            pgzx.guc.TestSuite_Guc,
            pgzx.xid.TestSuite_Xid,
            varatt.TestSuite_Varatt,
        },
    );
}
