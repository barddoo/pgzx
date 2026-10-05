//! A Postgres spinlock (`slock_t`) that guards a value.
//!
//! Mirrors pgrx's `PgSpinLock`. The lock and its data live in one struct, so
//! the type can be placed in shared memory and used from every backend.
//!
//! ```zig
//! const Counter = struct {
//!     pub const SHMEM_NAME = "my_counter";
//!     lock: SpinLock(u64) = .init(0),
//! };
//!
//! const guard = counter.lock.acquire();
//! defer guard.release();
//! guard.data.* += 1;
//! ```
//!
//! Spinlocks are for a few instructions at a time. While one is held do not
//! call anything that can raise a Postgres error, allocate, take another
//! lock, or wait: interrupts are not held off, and an error would longjmp
//! past `release` and leave the lock taken. Prefer `LWLock`s for anything
//! longer.
//!
//! The lock does not handle poisoning, and is not reentrant.

const std = @import("std");

const pg = @import("pgzx_pgsys");

pub fn SpinLock(comptime T: type) type {
    return struct {
        slock: pg.slock_t,
        data: T,

        const Self = @This();

        /// Create an unlocked spinlock holding `value`. The result can be
        /// copied freely until it is shared, which is how `shmem` initializes
        /// shared state.
        pub fn init(value: T) Self {
            var self: Self = .{ .slock = 0, .data = value };
            pg.pgzx_spin_init(&self.slock);
            return self;
        }

        pub const Guard = struct {
            data: *T,
            slock: *pg.slock_t,

            /// Unlock. The guard must not be used afterwards.
            pub fn release(self: Guard) void {
                pg.pgzx_spin_release(self.slock);
            }
        };

        /// Spin until the lock is taken. Call `release` on the guard when done.
        pub fn acquire(self: *Self) Guard {
            pg.pgzx_spin_acquire(&self.slock);
            return .{ .data = &self.data, .slock = &self.slock };
        }

        /// Whether the lock is currently held. Only meaningful as a hint or in
        /// assertions. Not available on Postgres 19 or later, which removed
        /// `SpinLockFree`; it then always returns false.
        pub fn isLocked(self: *Self) bool {
            return !pg.pgzx_spin_is_free(&self.slock);
        }
    };
}

pub const TestSuite_SpinLock = struct {
    const testing = std.testing;

    pub fn testAcquireRelease() !void {
        var lock: SpinLock(u32) = .init(5);

        {
            const guard = lock.acquire();
            defer guard.release();
            try testing.expectEqual(@as(u32, 5), guard.data.*);
            guard.data.* += 1;
        }

        const guard = lock.acquire();
        defer guard.release();
        try testing.expectEqual(@as(u32, 6), guard.data.*);
    }

    pub fn testIsLocked() !void {
        if (pg.PG_VERSION_NUM >= 190000) return;

        var lock: SpinLock(u8) = .init(0);
        try testing.expect(!lock.isLocked());

        const guard = lock.acquire();
        try testing.expect(lock.isLocked());

        guard.release();
        try testing.expect(!lock.isLocked());
    }

    pub fn testReacquireAfterRelease() !void {
        var lock: SpinLock(u64) = .init(0);
        for (0..1000) |_| {
            const guard = lock.acquire();
            guard.data.* += 1;
            guard.release();
        }

        const guard = lock.acquire();
        defer guard.release();
        try testing.expectEqual(@as(u64, 1000), guard.data.*);
    }

    pub fn testStructData() !void {
        const Stats = extern struct { hits: u32, misses: u32 };
        var lock: SpinLock(Stats) = .init(.{ .hits = 1, .misses = 2 });

        const guard = lock.acquire();
        defer guard.release();
        guard.data.hits += 10;
        try testing.expectEqual(@as(u32, 11), guard.data.hits);
        try testing.expectEqual(@as(u32, 2), guard.data.misses);
    }
};
