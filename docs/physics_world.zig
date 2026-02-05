const std = @import("std");
const c2 = @import("pure_zig_c2.zig");

pub const Body = struct {
    // State
    pos: c2.Vec2,
    vel: c2.Vec2,
    force: c2.Vec2,

    // Properties
    mass: f32,
    inv_mass: f32,
    restitution: f32 = 0.5, // Bounciness (0.0 = brick, 1.0 = superball)

    // Collision
    shape: c2.Shape,

    pub fn init(shape: c2.Shape, x: f32, y: f32, mass: f32) Body {
        return .{
            .pos = c2.Vec2.init(x, y),
            .vel = c2.Vec2.init(0, 0),
            .force = c2.Vec2.init(0, 0),
            .mass = mass,
            .inv_mass = if (mass == 0) 0 else 1.0 / mass,
            .shape = shape,
        };
    }

    pub fn applyForce(self: *Body, f: c2.Vec2) void {
        self.force = self.force.add(f);
    }
};

pub const World = struct {
    bodies: std.ArrayList(*Body),
    gravity: c2.Vec2,
    iterations: i32,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .bodies = std.ArrayList(*Body).init(allocator),
            .gravity = c2.Vec2.init(0, -9.8), // Standard Earth gravity
            .iterations = 10, // Higher = more stable stacking
        };
    }

    pub fn deinit(self: *World) void {
        self.bodies.deinit();
    }

    pub fn addBody(self: *World, body: *Body) !void {
        try self.bodies.append(body);
    }

    pub fn step(self: *World, dt: f32) void {
        // 1. Integrate Forces (Gravity + Applied)
        for (self.bodies.items) |b| {
            if (b.inv_mass == 0) continue; // Static bodies don't move

            // F = ma -> a = F/m -> a = F * inv_mass
            // Gravity is applied as acceleration directly
            const accel = self.gravity.add(b.force.mul(b.inv_mass));
            b.vel = b.vel.add(accel.mul(dt));
            b.pos = b.pos.add(b.vel.mul(dt));
            b.force = c2.Vec2.init(0, 0); // Clear forces
        }

        // 2. Collision Detection & Resolution
        // We run this multiple times per frame for stability (Solver Iterations)
        var i: i32 = 0;
        while (i < self.iterations) : (i += 1) {

            // Naive O(N^2) loop.
            // In a real engine, a Broadphase (Quadtree/Grid) goes here.
            for (self.bodies.items, 0..) |A, idx_a| {
                for (self.bodies.items, 0..) |B, idx_b| {
                    if (idx_a >= idx_b) continue; // Avoid duplicate pairs and self-check
                    if (A.inv_mass == 0 and B.inv_mass == 0) continue; // Static vs Static

                    var m: c2.Manifold = undefined;

                    // Prepare Transforms
                    const tA = c2.Transform{ .p = A.pos, .r = c2.Rotation.identity() };
                    const tB = c2.Transform{ .p = B.pos, .r = c2.Rotation.identity() };

                    // pointers to shapes inside the body
                    c2.collide(&A.shape, &tA, &B.shape, &tB, &m);

                    if (m.count > 0) {
                        resolveCollision(A, B, &m);
                    }
                }
            }
        }
    }

    // This is the "Physics" part that c2 doesn't do for you
    fn resolveCollision(A: *Body, B: *Body, m: *const c2.Manifold) void {
        const e = @min(A.restitution, B.restitution);

        // c2 Normal points from A to B
        const normal = m.n;

        // 1. Positional Correction (Prevent Sinking)
        // Move bodies apart so they aren't overlapping anymore
        const percent = 0.2; // Penetration percentage to correct
        const slop = 0.01; // Penetration allowance
        const depth = @max(m.depths[0] - slop, 0.0);
        const correction_mag = (depth / (A.inv_mass + B.inv_mass)) * percent;
        const correction = normal.mul(correction_mag);

        A.pos = A.pos.sub(correction.mul(A.inv_mass));
        B.pos = B.pos.add(correction.mul(B.inv_mass));

        // 2. Velocity Resolution (Impulse)
        // Make them bounce off each other
        const rv = B.vel.sub(A.vel); // Relative velocity
        const velAlongNormal = rv.dot(normal);

        // Do not resolve if velocities are separating
        if (velAlongNormal > 0) return;

        // Calculate impulse scalar
        var j = -(1.0 + e) * velAlongNormal;
        j /= (A.inv_mass + B.inv_mass);

        // Apply impulse
        const impulse = normal.mul(j);
        A.vel = A.vel.sub(impulse.mul(A.inv_mass));
        B.vel = B.vel.add(impulse.mul(B.inv_mass));
    }
};
