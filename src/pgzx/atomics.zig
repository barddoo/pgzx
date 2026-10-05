//! Wrappers for Postgres' atomic integers (`pg_atomic_uint32`/`pg_atomic_uint64`).
//!
//! The types have the same layout as the C structs, so they can be used where
//! Postgres expects a `pg_atomic_uintN`, for instance in shared memory, and
//! `inner` can be passed to C code.
//!
//! The operations are implemented with Zig atomics instead of calling the
//! `pg_atomic_*` functions: those are `static inline` in `port/atomics.h` and
//! translate-c turns the read-modify-write ones into unresolvable externs.
//! The memory ordering follows `port/atomics.h`: `read`/`write` are plain
//! (relaxed) accesses with no barrier, and every read-modify-write operation,
//! as well as the `*Membarrier` variants, is a full barrier (sequentially
//! consistent).
//!
//! Atomics in shared memory must be initialized exactly once, by the process
//! that creates the segment, before other backends can see them.

const std = @import("std");

const pg = @import("pgzx_pgsys");

pub const Atomic32 = Atomic(u32, pg.pg_atomic_uint32);
pub const Atomic64 = Atomic(u64, pg.pg_atomic_uint64);

fn Atomic(comptime Int: type, comptime Inner: type) type {
    comptime {
        std.debug.assert(@sizeOf(Inner) == @sizeOf(Int));
        // `pg_atomic_uint64` must be naturally aligned, or 64-bit atomics are
        // not atomic on some platforms.
        std.debug.assert(@alignOf(Inner) >= @alignOf(Int));
    }

    return extern struct {
        inner: Inner,

        const Self = @This();

        /// Not atomic: only use before the value is shared.
        pub fn init(value: Int) Self {
            return .{ .inner = .{ .value = value } };
        }

        inline fn ptr(self: *Self) *Int {
            return &self.inner.value;
        }

        /// Read without a memory barrier.
        pub fn read(self: *Self) Int {
            return @atomicLoad(Int, self.ptr(), .monotonic);
        }

        /// Read with a full memory barrier.
        pub fn readMembarrier(self: *Self) Int {
            return @atomicLoad(Int, self.ptr(), .seq_cst);
        }

        /// Write without a memory barrier.
        pub fn write(self: *Self, value: Int) void {
            @atomicStore(Int, self.ptr(), value, .monotonic);
        }

        /// Write with a full memory barrier.
        pub fn writeMembarrier(self: *Self, value: Int) void {
            @atomicStore(Int, self.ptr(), value, .seq_cst);
        }

        /// Store `value` and return the previous one.
        pub fn exchange(self: *Self, value: Int) Int {
            return @atomicRmw(Int, self.ptr(), .Xchg, value, .seq_cst);
        }

        /// Store `new` if the current value equals `expected`. Returns null on
        /// success, or the value that was found when the comparison failed.
        /// Unlike `pg_atomic_compare_exchange_*` this does not take an
        /// in/out `expected` pointer; use the returned value to retry.
        pub fn compareExchange(self: *Self, expected: Int, new: Int) ?Int {
            return @cmpxchgStrong(Int, self.ptr(), expected, new, .seq_cst, .seq_cst);
        }

        /// Add `delta` (wrapping) and return the previous value.
        pub fn fetchAdd(self: *Self, delta: Int) Int {
            return @atomicRmw(Int, self.ptr(), .Add, delta, .seq_cst);
        }

        /// Subtract `delta` (wrapping) and return the previous value.
        pub fn fetchSub(self: *Self, delta: Int) Int {
            return @atomicRmw(Int, self.ptr(), .Sub, delta, .seq_cst);
        }

        pub fn fetchAnd(self: *Self, mask: Int) Int {
            return @atomicRmw(Int, self.ptr(), .And, mask, .seq_cst);
        }

        pub fn fetchOr(self: *Self, mask: Int) Int {
            return @atomicRmw(Int, self.ptr(), .Or, mask, .seq_cst);
        }

        /// Add `delta` (wrapping) and return the new value.
        pub fn addFetch(self: *Self, delta: Int) Int {
            return self.fetchAdd(delta) +% delta;
        }

        /// Subtract `delta` (wrapping) and return the new value.
        pub fn subFetch(self: *Self, delta: Int) Int {
            return self.fetchSub(delta) -% delta;
        }

        /// Raise the value to at least `target` and return the resulting
        /// value, which is larger than `target` if another thread got there
        /// first (`pg_atomic_monotonic_advance_*`).
        pub fn monotonicAdvance(self: *Self, target: Int) Int {
            var current = self.read();
            while (current < target) {
                current = self.compareExchange(current, target) orelse return target;
            }
            return current;
        }
    };
}

pub const TestSuite_Atomics = struct {
    const testing = std.testing;

    pub fn testLayoutMatchesPostgres() !void {
        try testing.expectEqual(@sizeOf(pg.pg_atomic_uint32), @sizeOf(Atomic32));
        try testing.expectEqual(@sizeOf(pg.pg_atomic_uint64), @sizeOf(Atomic64));
        try testing.expectEqual(@as(usize, 8), @alignOf(Atomic64));
    }

    pub fn testReadWrite32() !void {
        var a: Atomic32 = .init(7);
        try testing.expectEqual(@as(u32, 7), a.read());

        a.write(8);
        try testing.expectEqual(@as(u32, 8), a.readMembarrier());

        a.writeMembarrier(9);
        try testing.expectEqual(@as(u32, 9), a.read());
    }

    pub fn testExchange32() !void {
        var a: Atomic32 = .init(1);
        try testing.expectEqual(@as(u32, 1), a.exchange(2));
        try testing.expectEqual(@as(u32, 2), a.read());
    }

    pub fn testCompareExchange32() !void {
        var a: Atomic32 = .init(10);
        try testing.expectEqual(@as(?u32, null), a.compareExchange(10, 11));
        try testing.expectEqual(@as(u32, 11), a.read());
        try testing.expectEqual(@as(?u32, 11), a.compareExchange(10, 12));
        try testing.expectEqual(@as(u32, 11), a.read());
    }

    pub fn testArithmetic32() !void {
        var a: Atomic32 = .init(10);
        try testing.expectEqual(@as(u32, 10), a.fetchAdd(5));
        try testing.expectEqual(@as(u32, 20), a.addFetch(5));
        try testing.expectEqual(@as(u32, 20), a.fetchSub(3));
        try testing.expectEqual(@as(u32, 14), a.subFetch(3));
        try testing.expectEqual(@as(u32, 14), a.read());
    }

    pub fn testWrapping32() !void {
        var a: Atomic32 = .init(std.math.maxInt(u32));
        try testing.expectEqual(@as(u32, std.math.maxInt(u32)), a.fetchAdd(1));
        try testing.expectEqual(@as(u32, 0), a.read());
        try testing.expectEqual(@as(u32, std.math.maxInt(u32)), a.subFetch(1));
    }

    pub fn testBitOps32() !void {
        var a: Atomic32 = .init(0b1100);
        try testing.expectEqual(@as(u32, 0b1100), a.fetchAnd(0b0110));
        try testing.expectEqual(@as(u32, 0b0100), a.read());
        try testing.expectEqual(@as(u32, 0b0100), a.fetchOr(0b0011));
        try testing.expectEqual(@as(u32, 0b0111), a.read());
    }

    pub fn testOps64() !void {
        var a: Atomic64 = .init(1 << 40);
        try testing.expectEqual(@as(u64, 1 << 40), a.fetchAdd(1));
        try testing.expectEqual(@as(u64, (1 << 40) + 2), a.addFetch(1));
        try testing.expectEqual(@as(?u64, null), a.compareExchange((1 << 40) + 2, 5));
        try testing.expectEqual(@as(u64, 5), a.readMembarrier());
        try testing.expectEqual(@as(u64, 5), a.exchange(1 << 50));
        try testing.expectEqual(@as(u64, 1 << 50), a.read());
    }

    pub fn testMonotonicAdvance() !void {
        var a: Atomic64 = .init(10);
        try testing.expectEqual(@as(u64, 20), a.monotonicAdvance(20));
        try testing.expectEqual(@as(u64, 20), a.read());

        // Never moves backwards: the larger current value is returned.
        try testing.expectEqual(@as(u64, 20), a.monotonicAdvance(15));
        try testing.expectEqual(@as(u64, 20), a.read());
    }

    pub fn testInteropWithPostgresInit() !void {
        // The layout is shared with C: a value initialized through the
        // translated (non-RMW) Postgres API is visible through the wrapper.
        var a: Atomic32 = .init(0);
        pg.pg_atomic_init_u32(&a.inner, 123);
        try testing.expectEqual(@as(u32, 123), a.read());
        try testing.expectEqual(@as(u32, 123), pg.pg_atomic_read_u32(&a.inner));
    }
};
