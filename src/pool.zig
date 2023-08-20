const std = @import("std");
const t = @import("t.zig");

const Allocator = std.mem.Allocator;

const Error = error{
    PoolFull,
};

pub fn Pool(comptime E: type, comptime S: type) type {
    const initFnPtr = *const fn (S) anyerror!E;

    return struct {
        items: []E,
        available: usize,
        allocator: Allocator,
        initFn: initFnPtr,
        initState: S,
        mutex: std.Thread.Mutex,
        grow_pool: bool = true,

        const Self = @This();

        pub fn init(allocator: Allocator, size: usize, grow_pool: bool, initFn: initFnPtr, initState: S) !Self {
            const items = try allocator.alloc(E, size);

            std.log.debug("Creating pool with size {} and grow = {}", .{ size, grow_pool });

            for (0..size) |i| {
                items[i] = try initFn(initState);
            }

            return Self{
                .items = items,
                .initFn = initFn,
                .initState = initState,
                .available = size,
                .allocator = allocator,
                .grow_pool = grow_pool,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            for (self.items) |e| {
                e.deinit(allocator);
            }
            allocator.free(self.items);
        }

        pub fn acquire(self: *Self) !struct { E, bool } {
            const items = self.items;
            self.mutex.lock();
            const available = self.available;
            if (available == 0) {
                self.mutex.unlock();
                if (self.grow_pool) {
                    const e = try self.initFn(self.initState);
                    std.log.debug("Creating new resReq {}", .{e});
                    return .{ e, false };
                }
                    std.log.debug("Reject because pool is full", .{});
                return Error.PoolFull;
            }
            defer self.mutex.unlock();
            const new_available = available - 1;
            self.available = new_available;
            std.log.debug("Re-use item {} -> {}", .{new_available, items[new_available]});
            return .{ items[new_available], true };
        }

        pub fn release(self: *Self, e: E) void {
            const items = self.items;

            self.mutex.lock();
            const available = self.available;
            defer self.mutex.unlock();

            if (available < items.len) {
                items[available] = e;
                self.available = available + 1;
            }
        }

        pub fn deinitResource(self: *Self, e: E) void {
            e.deinit(self.allocator);
        }
    };
}

var id: i32 = 0;
const TestEntry = struct {
    id: i32,
    acquired: bool,
    deinited: bool,

    pub fn init(incr: i32) !*TestEntry {
        id += incr;
        var entry = try t.allocator.create(TestEntry);
        entry.id = id;
        entry.acquired = false;
        return entry;
    }

    pub fn deinit(self: *TestEntry, allocator: Allocator) void {
        self.deinited = true;
        allocator.destroy(self);
    }
};

test "pool: acquires & release" {
    id = 0;
    var p = try Pool(*TestEntry, i32).init(t.allocator, 2, TestEntry.init, 5);
    defer p.deinit();

    var e1 = try p.acquire();
    try t.expectEqual(@as(i32, 10), e1.id);
    try t.expectEqual(false, e1.deinited);

    var e2 = try p.acquire();
    try t.expectEqual(@as(i32, 5), e2.id);
    try t.expectEqual(false, e2.deinited);

    var e3 = try p.acquire();
    try t.expectEqual(@as(i32, 15), e3.id);
    try t.expectEqual(false, e3.deinited);

    var e4 = try p.acquire();
    try t.expectEqual(@as(i32, 15), e4.id);
    try t.expectEqual(false, e4.deinited);

    // released first, so back in the pool
    p.release(e3);
    try t.expectEqual(@as(i32, 15), e3.id);
    try t.expectEqual(false, e3.deinited);

    p.release(e2);
    try t.expectEqual(@as(i32, 5), e2.id);
    try t.expectEqual(false, e2.deinited);

    p.release(e1);
    p.release(e4);
    // TODO: how to test that e1 was properly released?
}

test "pool: threadsafety" {
    var p = try Pool(*TestEntry, i32).init(t.allocator, 4, TestEntry.init, 1);
    defer p.deinit();

    const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t3 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t4 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t5 = try std.Thread.spawn(.{}, testPool, .{&p});

    t1.join();
    t2.join();
    t3.join();
    t4.join();
    t5.join();
}

fn testPool(p: *Pool(*TestEntry, i32)) void {
    var r = t.getRandom();
    const random = r.random();

    for (0..5000) |_| {
        var e = p.acquire() catch unreachable;
        std.debug.assert(e.acquired == false);
        e.acquired = true;
        std.time.sleep(random.uintAtMost(u32, 100000));
        e.acquired = false;
        p.release(e);
    }
}
