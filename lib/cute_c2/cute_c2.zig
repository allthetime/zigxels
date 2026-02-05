const std = @import("std");
pub const c = @import("c.zig");

// ============================================================================
// Data Types
// ============================================================================
// We alias the C types directly. This means they are POD (Plain Old Data)
// structs compatible with C. You can initialize them using Zig struct syntax.

pub const Vec2 = c.c2v;
pub const Circle = c.c2Circle;
pub const AABB = c.c2AABB;
pub const Capsule = c.c2Capsule;
pub const Poly = c.c2Poly;
pub const Ray = c.c2Ray;
pub const Raycast = c.c2Raycast;
pub const Manifold = c.c2Manifold;

// ============================================================================
// Helpers
// ============================================================================

/// Helper to create a vector easily
pub inline fn vec2(x: f32, y: f32) Vec2 {
    return .{ .x = x, .y = y };
}

/// Helper to construct a Polygon.
/// c2MakePoly must be called to compute normals/hull for the collision to work,
/// which this helper does automatically.

//That is Zig's syntax for creating a **Pointer to an Array Literal** with an inferred length.

//Here is the breakdown of `&[_]c2.Vec2{ ... }`:

//1.  **`c2.Vec2{ ... }`**: This is the data.
//2.  **`[_]`**: "Make this an **Array**, but figure out the size (`_`) for me automatically based on how many items I typed."
//    *   *Without this, you'd have to type `[3]c2.Vec2`, and if you added a 4th point, you'd have to update the number manually.*
// 3.  **`&`**: "Store this array in memory and give me a **Reference** (pointer) to it."
//    // *   *Without this, you are creating the array "by value". When you pass it to a function, Zig might copy the entire array. Adding `&` is efficient—it just passes the address.*

// ### Why do we use it here?

// The function `makePoly` expects a **Slice** (`[]const Vec2`).

// In Zig, a **Pointer to an Array** (which is what `&[_]` creates) automatically converts to a **Slice**.
pub fn makePoly(verts: []const Vec2) Poly {
    if (verts.len > c.C2_MAX_POLYGON_VERTS) @panic("Too many vertices for c2Poly");

    var p: Poly = undefined;
    p.count = @intCast(verts.len);
    for (verts, 0..) |v, i| p.verts[i] = v;

    // Computes normals and convex hull
    c.c2MakePoly(&p);
    return p;
}

// ============================================================================
// Functional API (Zero-Cost Abstractions)
// ============================================================================

/// Boolean collision check.
/// Routes to the correct C function at compile-time based on argument types.
/// Usage: if (c2.check(player, wall)) { ... }
pub fn check(a: anytype, b: anytype) bool {
    const T1 = @TypeOf(a);
    const T2 = @TypeOf(b);

    // Circle vs X
    if (T1 == Circle and T2 == Circle) return c.c2CircletoCircle(a, b) != 0;
    if (T1 == Circle and T2 == AABB) return c.c2CircletoAABB(a, b) != 0;
    if (T1 == Circle and T2 == Capsule) return c.c2CircletoCapsule(a, b) != 0;
    if (T1 == Circle and T2 == Poly) return c.c2CircletoPoly(a, &b, null) != 0;

    // AABB vs X
    if (T1 == AABB and T2 == AABB) return c.c2AABBtoAABB(a, b) != 0;
    if (T1 == AABB and T2 == Capsule) return c.c2AABBtoCapsule(a, b) != 0;
    if (T1 == AABB and T2 == Poly) return c.c2AABBtoPoly(a, &b, null) != 0;

    // Capsule vs X
    if (T1 == Capsule and T2 == Capsule) return c.c2CapsuletoCapsule(a, b) != 0;
    if (T1 == Capsule and T2 == Poly) return c.c2CapsuletoPoly(a, &b, null) != 0;

    // Poly vs Poly
    if (T1 == Poly and T2 == Poly) return c.c2PolytoPoly(&a, null, &b, null) != 0;

    // Symmetric handling (swap args if no match found yet)
    // This allows check(aabb, circle) to work even if we only defined circle_vs_aabb above.
    if (hasCheck(T2, T1)) return check(b, a);

    @compileError("No boolean collision check implemented for types: " ++ @typeName(T1) ++ " and " ++ @typeName(T2));
}

/// Manifold generation (Physics resolution).
/// Returns a Manifold struct if collision occurred, null otherwise.
/// Usage: if (c2.collide(player, wall)) |m| { ... }
pub fn collide(a: anytype, b: anytype) ?Manifold {
    const T1 = @TypeOf(a);
    const T2 = @TypeOf(b);

    var m: Manifold = undefined;

    // We only check the primary combinations here.
    // Note: Manifolds are directional (Normal points from A to B), so swapping args
    // requires inverting the resulting normal, which we handle in the 'Symmetric' block.

    // Circle vs X
    if (T1 == Circle and T2 == Circle) {
        c.c2CircletoCircleManifold(a, b, &m);
        return result(m);
    }
    if (T1 == Circle and T2 == AABB) {
        c.c2CircletoAABBManifold(a, b, &m);
        return result(m);
    }
    if (T1 == Circle and T2 == Capsule) {
        c.c2CircletoCapsuleManifold(a, b, &m);
        return result(m);
    }
    if (T1 == Circle and T2 == Poly) {
        c.c2CircletoPolyManifold(a, &b, null, &m);
        return result(m);
    }

    // AABB vs X
    if (T1 == AABB and T2 == AABB) {
        c.c2AABBtoAABBManifold(a, b, &m);
        return result(m);
    }
    if (T1 == AABB and T2 == Capsule) {
        c.c2AABBtoCapsuleManifold(a, b, &m);
        return result(m);
    }
    if (T1 == AABB and T2 == Poly) {
        c.c2AABBtoPolyManifold(a, &b, null, &m);
        return result(m);
    }

    // Capsule vs X
    if (T1 == Capsule and T2 == Capsule) {
        c.c2CapsuletoCapsuleManifold(a, b, &m);
        return result(m);
    }
    if (T1 == Capsule and T2 == Poly) {
        c.c2CapsuletoPolyManifold(a, &b, null, &m);
        return result(m);
    }

    // Poly vs Poly
    if (T1 == Poly and T2 == Poly) {
        c.c2PolytoPolyManifold(&a, null, &b, null, &m);
        return result(m);
    }

    // Symmetric handling (flip normal)
    if (hasCollide(T2, T1)) {
        if (collide(b, a)) |flipped_m| {
            var ret = flipped_m;
            ret.n.x = -ret.n.x;
            ret.n.y = -ret.n.y;
            return ret;
        }
        return null;
    }

    @compileError("No collision manifold implementation found for types: " ++ @typeName(T1) ++ " and " ++ @typeName(T2));
}

/// Raycast check.
/// Returns Raycast info if hit, null otherwise.
/// Usage: if (c2.cast(ray, box)) |hit| { ... }
pub fn cast(ray: Ray, shape: anytype) ?Raycast {
    const T = @TypeOf(shape);
    var out: Raycast = undefined;
    var hit: c_int = 0;

    if (T == Circle) hit = c.c2RaytoCircle(ray, shape, &out);
    if (T == AABB) hit = c.c2RaytoAABB(ray, shape, &out);
    if (T == Capsule) hit = c.c2RaytoCapsule(ray, shape, &out);
    if (T == Poly) hit = c.c2RaytoPoly(ray, &shape, null, &out);

    if (T != Circle and T != AABB and T != Capsule and T != Poly) {
        @compileError("Raycasting not supported for type: " ++ @typeName(T));
    }

    if (hit != 0) return out;
    return null;
}

// ============================================================================
// Internal Utility (Compile-Time Logic)
// ============================================================================

fn result(m: Manifold) ?Manifold {
    return if (m.count > 0) m else null;
}

// Helper to determine if a forward definition exists, to safely trigger the swap logic.
fn hasCheck(T1: type, T2: type) bool {
    if (T1 == Circle and T2 == Circle) return true;
    if (T1 == Circle and T2 == AABB) return true;
    if (T1 == Circle and T2 == Capsule) return true;
    if (T1 == Circle and T2 == Poly) return true;
    if (T1 == AABB and T2 == AABB) return true;
    if (T1 == AABB and T2 == Capsule) return true;
    if (T1 == AABB and T2 == Poly) return true;
    if (T1 == Capsule and T2 == Capsule) return true;
    if (T1 == Capsule and T2 == Poly) return true;
    if (T1 == Poly and T2 == Poly) return true;
    return false;
}

fn hasCollide(T1: type, T2: type) bool {
    // Same matrix as check
    return hasCheck(T1, T2);
}
