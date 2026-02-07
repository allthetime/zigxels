const std = @import("std");

pub const NamedFn = struct {
    name: []const u8,
    func: *const fn () void,
};

pub fn Bencher(comptime functions: anytype) type {
    return struct {
        timer: std.time.Timer,
        runs: usize = 1_000_000,

        pub fn init(runs: ?usize) !@This() {
            return .{
                .timer = try std.time.Timer.start(),
                .runs = runs orelse 1_000_000,
            };
        }

        pub fn runAll(self: *@This()) void {
            // This loop is unrolled or resolved at compile-time!
            inline for (functions) |f| {
                self.timer.reset();
                for (0..self.runs) |i| f.func(i);
                const elapsed = self.timer.read() / 1_000_000;
                std.debug.print("{s}: {d}ms\n", .{ f.name, elapsed });
            }
        }
    };
}

// fn runC2Loop(i: usize) void {
//     const circle = collision.c2Circle{ .p = .{ .x = @as(f32, @floatFromInt(i % 100)), .y = @as(f32, @floatFromInt(i % 100)) }, .r = 5.0 };
//     const box = collision.c2AABB{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };
//     const collided = collision.c2CircletoAABB(circle, box) == 1;
//     std.mem.doNotOptimizeAway(collided);
// }

// fn runZ2Loop(i: usize) void {
//     const circle: z2.Circle = .{ .p = .{ .x = @as(f32, @floatFromInt(i % 100)), .y = @as(f32, @floatFromInt(i % 100)) }, .r = 5.0 };
//     const box: z2.AABB = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 20, .y = 20 } };
//     const collided = z2.circleToAABB(circle, box);
//     std.mem.doNotOptimizeAway(collided);
// }

// // Benchmarking Setup
// var bench = try Bencher(&.{
//     .{ .name = "C2 Optimized Loop", .func = &runC2Loop },
//     .{ .name = "Z2 Standard Loop", .func = &runZ2Loop },
// }).init(10_000_000);
// bench.runAll();
