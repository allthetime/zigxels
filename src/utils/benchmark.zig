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

// timer.reset();
// runC2Loop();
// std.debug.print("C2: {d}ms\n", .{timer.read() / 1_000_000});
