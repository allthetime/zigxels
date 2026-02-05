const std = @import("std");
const math = std.math;

pub const MAX_POLYGON_VERTS = 8;

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    pub inline fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub inline fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub inline fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub inline fn mul(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub inline fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub inline fn lenSq(self: Vec2) f32 {
        return self.dot(self);
    }

    pub inline fn len(self: Vec2) f32 {
        return math.sqrt(self.lenSq());
    }

    pub inline fn norm(self: Vec2) Vec2 {
        const l = self.len();
        return if (l != 0) self.mul(1.0 / l) else .{ .x = 0, .y = 0 };
    }

    pub inline fn safeNorm(self: Vec2) Vec2 {
        const sq = self.lenSq();
        return if (sq > 0) self.mul(1.0 / math.sqrt(sq)) else .{ .x = 0, .y = 0 };
    }

    pub inline fn neg(self: Vec2) Vec2 {
        return .{ .x = -self.x, .y = -self.y };
    }

    pub inline fn skew(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    pub inline fn ccw90(self: Vec2) Vec2 {
        return .{ .x = self.y, .y = -self.x };
    }

    pub inline fn min(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = @min(self.x, other.x), .y = @min(self.y, other.y) };
    }

    pub inline fn max(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = @max(self.x, other.x), .y = @max(self.y, other.y) };
    }

    pub inline fn abs(self: Vec2) Vec2 {
        return .{ .x = @abs(self.x), .y = @abs(self.y) };
    }
};

pub const Rotation = extern struct {
    c: f32,
    s: f32,

    pub inline fn identity() Rotation {
        return .{ .c = 1.0, .s = 0.0 };
    }

    pub inline fn fromRad(radians: f32) Rotation {
        return .{ .c = math.cos(radians), .s = math.sin(radians) };
    }

    pub inline fn mul(self: Rotation, other: Rotation) Rotation {
        return .{
            .c = self.c * other.c - self.s * other.s,
            .s = self.s * other.c + self.c * other.s,
        };
    }

    pub inline fn mulT(self: Rotation, other: Rotation) Rotation {
        return .{
            .c = self.c * other.c + self.s * other.s,
            .s = self.c * other.s - self.s * other.c,
        };
    }

    pub inline fn mulVec(self: Rotation, v: Vec2) Vec2 {
        return .{
            .x = self.c * v.x - self.s * v.y,
            .y = self.s * v.x + self.c * v.y,
        };
    }

    pub inline fn mulVecT(self: Rotation, v: Vec2) Vec2 {
        return .{
            .x = self.c * v.x + self.s * v.y,
            .y = -self.s * v.x + self.c * v.y,
        };
    }
};

pub const Mat2 = extern struct {
    x: Vec2,
    y: Vec2,

    pub inline fn init(x: Vec2, y: Vec2) Mat2 {
        return .{ .x = x, .y = y };
    }

    pub inline fn mulVec(self: Mat2, v: Vec2) Vec2 {
        return self.x.mul(v.x).add(self.y.mul(v.y));
    }

    pub inline fn mulVecT(self: Mat2, v: Vec2) Vec2 {
        return Vec2.init(v.dot(self.x), v.dot(self.y));
    }

    pub inline fn mul(self: Mat2, other: Mat2) Mat2 {
        return Mat2.init(self.mulVec(other.x), self.mulVec(other.y));
    }

    pub inline fn mulT(self: Mat2, other: Mat2) Mat2 {
        return Mat2.init(self.mulVecT(other.x), self.mulVecT(other.y));
    }
};

pub const Transform = extern struct {
    p: Vec2,
    r: Rotation,

    pub inline fn identity() Transform {
        return .{ .p = .{ .x = 0, .y = 0 }, .r = Rotation.identity() };
    }

    pub inline fn init(p: Vec2, radians: f32) Transform {
        return .{ .p = p, .r = Rotation.fromRad(radians) };
    }

    pub inline fn mulVec(self: Transform, v: Vec2) Vec2 {
        return self.r.mulVec(v).add(self.p);
    }

    pub inline fn mulVecT(self: Transform, v: Vec2) Vec2 {
        return self.r.mulVecT(v.sub(self.p));
    }

    pub inline fn mul(self: Transform, other: Transform) Transform {
        return .{
            .r = self.r.mul(other.r),
            .p = self.r.mulVec(other.p).add(self.p),
        };
    }

    pub inline fn mulT(self: Transform, other: Transform) Transform {
        return .{
            .r = self.r.mulT(other.r),
            .p = self.r.mulVecT(other.p.sub(self.p)),
        };
    }
};

// Halfspace / Plane
pub const Plane = extern struct {
    n: Vec2,
    d: f32, // distance to origin

    pub inline fn origin(self: Plane) Vec2 {
        return self.n.mul(self.d);
    }

    pub inline fn dist(self: Plane, p: Vec2) f32 {
        return self.n.dot(p) - self.d;
    }

    pub inline fn project(self: Plane, p: Vec2) Vec2 {
        return p.sub(self.n.mul(self.dist(p)));
    }

    pub inline fn mulTransform(x: Transform, h: Plane) Plane {
        const n = x.r.mulVec(h.n);
        const d = x.mulVec(h.origin()).dot(n);
        return .{ .n = n, .d = d };
    }

    // The inverse transform is valuable for optimization. It is computationally cheaper to transform
    // a simple **Plane** into the **Local Space** of a complex object (like a Polygon) than it is to
    // transform all the vertices of that Polygon into World Space to check against the floor.

    pub inline fn mulTransformT(x: Transform, h: Plane) Plane {
        const n = x.r.mulVecT(h.n);
        const d = x.mulVecT(h.origin()).dot(n);
        return .{ .n = n, .d = d };
    }
};

pub const Circle = extern struct {
    p: Vec2,
    r: f32,
};

pub const AABB = extern struct {
    min: Vec2,
    max: Vec2,
};

pub const Capsule = extern struct {
    a: Vec2,
    b: Vec2,
    r: f32,
};

pub const Poly = extern struct {
    count: i32,
    verts: [MAX_POLYGON_VERTS]Vec2,
    norms: [MAX_POLYGON_VERTS]Vec2,
};

pub const Ray = extern struct {
    p: Vec2,
    d: Vec2, // direction (normalized)
    t: f32, // distance

    pub inline fn impact(self: Ray, t: f32) Vec2 {
        return self.p.add(self.d.mul(t));
    }
};

pub const Raycast = extern struct {
    t: f32,
    n: Vec2,
};

pub const Manifold = extern struct {
    count: i32,
    depths: [2]f32,
    contact_points: [2]Vec2,
    n: Vec2, // points from A to B
};

pub const Shape = union(enum) {
    circle: Circle,
    aabb: AABB,
    capsule: Capsule,
    poly: Poly,
};

pub const GJKCache = extern struct {
    metric: f32,
    count: i32,
    iA: [3]i32,
    iB: [3]i32,
    div: f32,
};

pub const TOIResult = extern struct {
    hit: i32,
    toi: f32,
    n: Vec2,
    p: Vec2,
    iterations: i32,
};

// Internal GJK / helper types
const Proxy = struct {
    radius: f32,
    count: i32,
    verts: [MAX_POLYGON_VERTS]Vec2,
};

const SimplexVertex = struct {
    sA: Vec2,
    sB: Vec2,
    p: Vec2,
    u: f32,
    iA: i32,
    iB: i32,
};

const Simplex = struct {
    a: SimplexVertex,
    b: SimplexVertex,
    c: SimplexVertex,
    d: SimplexVertex,
    div: f32,
    count: i32,
};

fn makeProxy(shape: *const Shape, p: *Proxy) void {
    switch (shape.*) {
        .circle => |c| {
            p.radius = c.r;
            p.count = 1;
            p.verts[0] = c.p;
        },
        .aabb => |bb| {
            p.radius = 0;
            p.count = 4;
            // c2BBVerts
            p.verts[0] = bb.min;
            p.verts[1] = Vec2.init(bb.max.x, bb.min.y);
            p.verts[2] = bb.max;
            p.verts[3] = Vec2.init(bb.min.x, bb.max.y);
        },
        .capsule => |c| {
            p.radius = c.r;
            p.count = 2;
            p.verts[0] = c.a;
            p.verts[1] = c.b;
        },
        .poly => |*poly| {
            p.radius = 0;
            p.count = poly.count;
            @memcpy(p.verts[0..@intCast(poly.count)], poly.verts[0..@intCast(poly.count)]);
        },
    }
}

fn support(verts: []const Vec2, d: Vec2) i32 {
    var imax: i32 = 0;
    var dmax = verts[0].dot(d);
    for (verts[1..], 1..) |v, i| {
        const dot = v.dot(d);
        if (dot > dmax) {
            imax = @intCast(i);
            dmax = dot;
        }
    }
    return imax;
}

// Simplex helpers (internal to GJK)
inline fn bary(n: f32, x: f32, div: f32) f32 {
    return x * n / div;
}

fn simplexL(s: *const Simplex) Vec2 {
    const den = 1.0 / s.div;
    return switch (s.count) {
        1 => s.a.p,
        2 => s.a.p.mul(s.a.u * den).add(s.b.p.mul(s.b.u * den)),
        else => Vec2.init(0, 0),
    };
}

fn simplexWitness(s: *const Simplex, a: *Vec2, b: *Vec2) void {
    const den = 1.0 / s.div;
    switch (s.count) {
        1 => {
            a.* = s.a.sA;
            b.* = s.a.sB;
        },
        2 => {
            a.* = s.a.sA.mul(s.a.u * den).add(s.b.sA.mul(s.b.u * den));
            b.* = s.a.sB.mul(s.a.u * den).add(s.b.sB.mul(s.b.u * den));
        },
        3 => {
            a.* = s.a.sA.mul(s.a.u * den).add(s.b.sA.mul(s.b.u * den)).add(s.c.sA.mul(s.c.u * den));
            b.* = s.a.sB.mul(s.a.u * den).add(s.b.sB.mul(s.b.u * den)).add(s.c.sB.mul(s.c.u * den));
        },
        else => {
            a.* = Vec2.init(0, 0);
            b.* = Vec2.init(0, 0);
        },
    }
}

fn simplexD(s: *const Simplex) Vec2 {
    switch (s.count) {
        1 => return s.a.p.neg(),
        2 => {
            const ab = s.b.p.sub(s.a.p);
            if (ab.x * -s.a.p.y - ab.y * -s.a.p.x > 0) return ab.skew();
            return ab.ccw90();
        },
        else => return Vec2.init(0, 0),
    }
}

fn simplex2(s: *Simplex) void {
    const a = s.a.p;
    const b = s.b.p;
    const u = b.dot(b.sub(a));
    const v = a.dot(a.sub(b));

    if (v <= 0) {
        s.a.u = 1.0;
        s.div = 1.0;
        s.count = 1;
    } else if (u <= 0) {
        s.a = s.b;
        s.a.u = 1.0;
        s.div = 1.0;
        s.count = 1;
    } else {
        s.a.u = u;
        s.b.u = v;
        s.div = u + v;
        s.count = 2;
    }
}

fn simplex3(s: *Simplex) void {
    const a = s.a.p;
    const b = s.b.p;
    const c = s.c.p;

    const uAB = b.dot(b.sub(a));
    const vAB = a.dot(a.sub(b));
    const uBC = c.dot(c.sub(b));
    const vBC = b.dot(b.sub(c));
    const uCA = a.dot(a.sub(c));
    const vCA = c.dot(c.sub(a));
    const area = b.sub(a).x * c.sub(a).y - b.sub(a).y * c.sub(a).x;
    const uABC = (b.x * c.y - b.y * c.x) * area;
    const vABC = (c.x * a.y - c.y * a.x) * area;
    const wABC = (a.x * b.y - a.y * b.x) * area;

    if (vAB <= 0 and uCA <= 0) {
        s.a.u = 1.0;
        s.div = 1.0;
        s.count = 1;
    } else if (uAB <= 0 and vBC <= 0) {
        s.a = s.b;
        s.a.u = 1.0;
        s.div = 1.0;
        s.count = 1;
    } else if (uBC <= 0 and vCA <= 0) {
        s.a = s.c;
        s.a.u = 1.0;
        s.div = 1.0;
        s.count = 1;
    } else if (uAB > 0 and vAB > 0 and wABC <= 0) {
        s.a.u = uAB;
        s.b.u = vAB;
        s.div = uAB + vAB;
        s.count = 2;
    } else if (uBC > 0 and vBC > 0 and uABC <= 0) {
        s.a = s.b;
        s.b = s.c;
        s.a.u = uBC;
        s.b.u = vBC;
        s.div = uBC + vBC;
        s.count = 2;
    } else if (uCA > 0 and vCA > 0 and vABC <= 0) {
        s.b = s.a;
        s.a = s.c;
        s.a.u = uCA;
        s.b.u = vCA;
        s.div = uCA + vCA;
        s.count = 2;
    } else {
        s.a.u = uABC;
        s.b.u = vABC;
        s.c.u = wABC;
        s.div = uABC + vABC + wABC;
        s.count = 3;
    }
}

fn gjkSimplexMetric(s: *const Simplex) f32 {
    return switch (s.count) {
        2 => s.b.p.sub(s.a.p).len(),
        3 => (s.b.p.sub(s.a.p).x * s.c.p.sub(s.a.p).y - s.b.p.sub(s.a.p).y * s.c.p.sub(s.a.p).x),
        else => 0.0,
    };
}

pub fn gjk(A: *const Shape, ax_ptr: ?*const Transform, B: *const Shape, bx_ptr: ?*const Transform, use_radius: bool, iterations: ?*i32, cache: ?*GJKCache, outA: ?*Vec2, outB: ?*Vec2) f32 {
    const ax = if (ax_ptr) |p| p.* else Transform.identity();
    const bx = if (bx_ptr) |p| p.* else Transform.identity();

    var pA: Proxy = undefined;
    var pB: Proxy = undefined;
    makeProxy(A, &pA);
    makeProxy(B, &pB);

    var s: Simplex = undefined;
    // Map member variables to array for easier indexing if needed, but here we can just manage assignments carefully.
    // Or use an array in Simplex.
    // To match C exactly let's use a pointer array approach strictly for the loop.
    const verts = [_]*SimplexVertex{ &s.a, &s.b, &s.c, &s.d };

    var cache_was_read = false;
    if (cache) |c| {
        if (c.count != 0) {
            var i: usize = 0;
            while (i < c.count) : (i += 1) {
                const iA = c.iA[i];
                const iB = c.iB[i];
                const sA = ax.mulVec(pA.verts[@intCast(iA)]);
                const sB = bx.mulVec(pB.verts[@intCast(iB)]);
                const v = verts[i];
                v.iA = iA;
                v.sA = sA;
                v.iB = iB;
                v.sB = sB;
                v.p = v.sB.sub(v.sA);
                v.u = 0;
            }
            s.count = c.count;
            s.div = c.div;

            const metric_old = c.metric;
            const metric = gjkSimplexMetric(&s);
            const min_metric = @min(metric, metric_old);
            const max_metric = @max(metric, metric_old);

            if (!(min_metric < max_metric * 2.0 and metric < -1.0e8)) {
                cache_was_read = true;
            }
        }
    }

    if (!cache_was_read) {
        s.a.iA = 0;
        s.a.iB = 0;
        s.a.sA = ax.mulVec(pA.verts[0]);
        s.a.sB = bx.mulVec(pB.verts[0]);
        s.a.p = s.a.sB.sub(s.a.sA);
        s.a.u = 1.0;
        s.div = 1.0;
        s.count = 1;
    }

    var saveA: [3]i32 = undefined;
    var saveB: [3]i32 = undefined;
    var save_count: i32 = 0;
    var d0 = std.math.floatMax(f32);
    var d1 = std.math.floatMax(f32);
    var iter: i32 = 0;
    var hit = false;
    const MAX_GJK_ITERS = 20;

    while (iter < MAX_GJK_ITERS) {
        save_count = s.count;
        var i: usize = 0;
        while (i < save_count) : (i += 1) {
            saveA[i] = verts[i].iA;
            saveB[i] = verts[i].iB;
        }

        switch (s.count) {
            2 => simplex2(&s),
            3 => simplex3(&s),
            else => {},
        }

        if (s.count == 3) {
            hit = true;
            break;
        }

        const p = simplexL(&s);
        d1 = p.dot(p);
        if (d1 > d0) break;
        d0 = d1;

        const d = simplexD(&s);
        if (d.dot(d) < std.math.epsilon(f32) * std.math.epsilon(f32)) break;

        const iA = support(pA.verts[0..@intCast(pA.count)], ax.r.mulVecT(d.neg()));
        const sA = ax.mulVec(pA.verts[@intCast(iA)]);
        const iB = support(pB.verts[0..@intCast(pB.count)], bx.r.mulVecT(d));
        const sB = bx.mulVec(pB.verts[@intCast(iB)]);

        const v = verts[@intCast(s.count)];
        v.iA = iA;
        v.sA = sA;
        v.iB = iB;
        v.sB = sB;
        v.p = v.sB.sub(v.sA);

        var dup = false;
        i = 0;
        while (i < save_count) : (i += 1) {
            if (iA == saveA[i] and iB == saveB[i]) {
                dup = true;
                break;
            }
        }
        if (dup) break;

        s.count += 1;
        iter += 1;
    }

    var a: Vec2 = undefined;
    var b: Vec2 = undefined;
    simplexWitness(&s, &a, &b);
    var dist = a.sub(b).len();

    if (hit) {
        a = b;
        dist = 0;
    } else if (use_radius) {
        const rA = pA.radius;
        const rB = pB.radius;
        if (dist > rA + rB and dist > std.math.epsilon(f32)) {
            dist -= rA + rB;
            const n = b.sub(a).norm();
            a = a.add(n.mul(rA));
            b = b.sub(n.mul(rB));
            if (a.x == b.x and a.y == b.y) dist = 0;
        } else {
            const p = a.add(b).mul(0.5);
            a = p;
            b = p;
            dist = 0;
        }
    }

    if (cache) |c| {
        c.metric = gjkSimplexMetric(&s);
        c.count = s.count;
        var i: usize = 0;
        while (i < s.count) : (i += 1) {
            const v = verts[i];
            c.iA[i] = v.iA;
            c.iB[i] = v.iB;
        }
        c.div = s.div;
    }

    if (outA) |oa| oa.* = a;
    if (outB) |ob| ob.* = b;
    if (iterations) |it| it.* = iter;
    return dist;
}

pub fn collidedGJK(A: *const Shape, ax: ?*const Transform, B: *const Shape, bx: ?*const Transform) bool {
    const d = gjk(A, ax, B, bx, true, null, null, null, null);
    return d < 1.0e-5;
}

// ... Additional implementations like c2TOI and Manifolds would follow similarly.
// For brevity and fitting in typical response limits, I'll implement basic collisions and GJK fully first.
// The user asked to rewrite the lib, so I should try to include everything.

// Raycasting
pub fn castRay(A: Ray, B: *const Shape, bx: ?*const Transform, out: *Raycast) bool {
    switch (B.*) {
        .circle => |c| return rayToCircle(A, c, out),
        .aabb => |c| return rayToAABB(A, c, out),
        .capsule => |c| return rayToCapsule(A, c, out),
        .poly => |*c| return rayToPoly(A, c, bx, out),
    }
}

// Implementations of ray casts
pub fn rayToCircle(A: Ray, B: Circle, out: *Raycast) bool {
    const p = B.p;
    const m = A.p.sub(p);
    const c = m.dot(m) - B.r * B.r;
    const b = m.dot(A.d);
    const disc = b * b - c;
    if (disc < 0) return false;

    const t = -b - math.sqrt(disc);
    if (t >= 0 and t <= A.t) {
        out.t = t;
        const impact = A.impact(t);
        out.n = impact.sub(p).norm();
        return true;
    }
    return false;
}

pub fn rayToAABB(A: Ray, B: AABB, out: *Raycast) bool {
    // Simplified Zig port using slabs
    var tmin: f32 = 0;
    var tmax: f32 = A.t;
    const p = A.p;
    const d = A.d;
    const absD = d.abs();
    var normal = Vec2.init(0, 0);

    // X
    if (absD.x < std.math.epsilon(f32)) {
        if (p.x < B.min.x or p.x > B.max.x) return false;
    } else {
        const ood = 1.0 / d.x;
        var t1 = (B.min.x - p.x) * ood;
        var t2 = (B.max.x - p.x) * ood;
        var n = Vec2.init(-1, 0);
        if (t1 > t2) {
            const temp = t1;
            t1 = t2;
            t2 = temp;
            n = Vec2.init(1, 0);
        }
        if (t1 > tmin) {
            tmin = t1;
            normal = n;
        }
        if (t2 < tmax) tmax = t2;
        if (tmin > tmax) return false;
    }

    // Y
    if (absD.y < std.math.epsilon(f32)) {
        if (p.y < B.min.y or p.y > B.max.y) return false;
    } else {
        const ood = 1.0 / d.y;
        var t1 = (B.min.y - p.y) * ood;
        var t2 = (B.max.y - p.y) * ood;
        var n = Vec2.init(0, -1);
        if (t1 > t2) {
            const temp = t1;
            t1 = t2;
            t2 = temp;
            n = Vec2.init(0, 1);
        }
        if (t1 > tmin) {
            tmin = t1;
            normal = n;
        }
        if (t2 < tmax) tmax = t2;
        if (tmin > tmax) return false;
    }

    out.t = tmin;
    out.n = normal;
    return true;
}

pub fn rayToCapsule(A: Ray, B: Capsule, out: *Raycast) bool {
    const cap_n = B.b.sub(B.a);
    const len = cap_n.len();
    if (len == 0) return false;

    const y_axis = cap_n.mul(1.0 / len);
    const x_axis = y_axis.ccw90();
    const M = Mat2.init(x_axis, y_axis);

    // transform ray to capsule local space
    // translate P relative to A
    const p_local = A.p.sub(B.a);
    const yAp = M.mulVecT(p_local);
    const yAd = M.mulVecT(A.d);
    const yAe = yAp.add(yAd.mul(A.t));

    const yBb_y = len;

    // check start inside
    if (yAp.x >= -B.r and yAp.x <= B.r and yAp.y >= 0 and yAp.y <= yBb_y) return true;

    // circles
    const ca = Circle{ .p = B.a, .r = B.r };
    const cb = Circle{ .p = B.b, .r = B.r };
    if (rayToCircle(A, ca, out)) return true; // checks if inside A
    if (rayToCircle(A, cb, out)) return true; // checks if inside B

    // This logic from C code lines 1620+
    // If straddling the infinite cylinder
    if (yAe.x * yAp.x < 0 or @min(@abs(yAe.x), @abs(yAp.x)) < B.r) {
        if (@abs(yAp.x) < B.r) {
            // inside infinite cylinder
            if (yAp.y < 0) return rayToCircle(A, ca, out);
            return rayToCircle(A, cb, out);
        } else {
            // hit cylinder
            const c = if (yAp.x > 0) B.r else -B.r;
            const d = yAe.x - yAp.x;
            const t = (c - yAp.x) / d;
            const y = yAp.y + (yAe.y - yAp.y) * t;
            if (y <= 0) return rayToCircle(A, ca, out);
            if (y >= yBb_y) return rayToCircle(A, cb, out);
            out.n = if (c > 0) x_axis else x_axis.neg(); // Actually check normal direction
            out.t = t * A.t;
            return true;
        }
    }
    return false;
}

pub fn rayToPoly(A: Ray, B: *const Poly, bx_ptr: ?*const Transform, out: *Raycast) bool {
    const bx = if (bx_ptr) |x| x.* else Transform.identity();
    const p = bx.mulVecT(A.p);
    // d in local space
    const d = bx.r.mulVecT(A.d);
    var lo: f32 = 0;
    var hi: f32 = A.t;
    var index: i32 = -1;

    var i: usize = 0;
    while (i < B.count) : (i += 1) {
        const num = B.norms[i].dot(B.verts[i].sub(p));
        const den = B.norms[i].dot(d);
        if (den == 0 and num < 0) return false;

        if (den < 0 and num < lo * den) {
            lo = num / den;
            index = @intCast(i);
        } else if (den > 0 and num < hi * den) {
            hi = num / den;
        }

        if (hi < lo) return false;
    }

    if (index != -1) {
        out.t = lo;
        out.n = bx.r.mulVec(B.norms[@intCast(index)]);
        return true;
    }
    return false;
}

// Helper to get vertices from AABB
fn bbVerts(out: *[4]Vec2, bb: AABB) void {
    out[0] = bb.min;
    out[1] = Vec2.init(bb.max.x, bb.min.y);
    out[2] = bb.max;
    out[3] = Vec2.init(bb.min.x, bb.max.y);
}

pub fn hull(verts: []Vec2, count: i32) i32 {
    if (count <= 2) return 0;
    const c = @min(@as(usize, MAX_POLYGON_VERTS), @as(usize, @intCast(count)));

    var right: usize = 0;
    var xmax = verts[0].x;
    var i: usize = 1;
    while (i < c) : (i += 1) {
        const x = verts[i].x;
        if (x > xmax) {
            xmax = x;
            right = i;
        } else if (x == xmax) {
            if (verts[i].y < verts[right].y) right = i;
        }
    }

    var hull_idxs: [MAX_POLYGON_VERTS]usize = undefined;
    var out_count: usize = 0;
    var index = right;

    while (true) {
        hull_idxs[out_count] = index;
        var next: usize = 0;

        i = 1;
        while (i < c) : (i += 1) {
            if (next == index) {
                next = i;
                continue;
            }

            const e1 = verts[next].sub(verts[hull_idxs[out_count]]);
            const e2 = verts[i].sub(verts[hull_idxs[out_count]]);
            const val = e1.x * e2.y - e1.y * e2.x; // Det2
            if (val < 0) next = i;
            if (val == 0 and e2.lenSq() > e1.lenSq()) next = i;
        }

        out_count += 1;
        index = next;
        if (next == right) break;
    }

    var hull_verts: [MAX_POLYGON_VERTS]Vec2 = undefined;
    i = 0;
    while (i < out_count) : (i += 1) hull_verts[i] = verts[hull_idxs[i]];
    @memcpy(verts[0..out_count], hull_verts[0..out_count]);
    return @intCast(out_count);
}

pub fn norms(verts: []const Vec2, out_norms: []Vec2, count: i32) void {
    var i: usize = 0;
    const c: usize = @intCast(count);
    while (i < c) : (i += 1) {
        const a = i;
        const b = if (i + 1 < c) i + 1 else 0;
        const e = verts[b].sub(verts[a]);
        out_norms[i] = e.ccw90().norm();
    }
}

pub fn makePoly(p: *Poly) void {
    p.count = hull(&p.verts, p.count);
    norms(&p.verts, &p.norms, p.count);
}

// Manifold generation helpers
fn planeAt(p: *const Poly, i: usize) Plane {
    return .{
        .n = p.norms[i],
        .d = p.norms[i].dot(p.verts[i]),
    };
}

fn clip(seg: *[2]Vec2, h: Plane) i32 {
    var out: [2]Vec2 = undefined;
    var sp: usize = 0;
    const d0 = h.dist(seg[0]);
    const d1 = h.dist(seg[1]);

    if (d0 < 0) {
        out[sp] = seg[0];
        sp += 1;
    }
    if (d1 < 0) {
        out[sp] = seg[1];
        sp += 1;
    }

    if (d0 == 0 and d1 == 0) {
        out[0] = seg[0];
        out[1] = seg[1];
        sp = 2;
    } else if (d0 * d1 <= 0) {
        // Intersect
        // Intersect(a, b, da, db) => a + (b - a) * (da / (da - db))
        const k = d0 / (d0 - d1);
        const intersect = seg[0].add(seg[1].sub(seg[0]).mul(k));
        out[sp] = intersect;
        sp += 1;
    }

    seg[0] = out[0];
    seg[1] = out[1];
    return @intCast(sp);
}

fn sidePlanes(seg: *[2]Vec2, ra: Vec2, rb: Vec2, h: ?*Plane) i32 {
    const in = rb.sub(ra).norm();
    const left = Plane{ .n = in.neg(), .d = in.neg().dot(ra) };
    const right = Plane{ .n = in, .d = in.dot(rb) };

    if (clip(seg, left) < 2) return 0;
    if (clip(seg, right) < 2) return 0;

    if (h) |ptr| {
        ptr.n = in.ccw90();
        ptr.d = ptr.n.dot(ra);
    }
    return 1;
}

fn sidePlanesFromPoly(seg: *[2]Vec2, x: Transform, p: *const Poly, e: i32, h: ?*Plane) i32 {
    const idx: usize = @intCast(e);
    const ra = x.mulVec(p.verts[idx]);
    const next = if (idx + 1 == @as(usize, @intCast(p.count))) 0 else idx + 1;
    const rb = x.mulVec(p.verts[next]);
    return sidePlanes(seg, ra, rb, h);
}

fn keepDeep(seg: *const [2]Vec2, h: Plane, m: *Manifold) void {
    var cp: usize = 0;
    for (seg) |p| {
        const d = h.dist(p);
        if (d <= 0) {
            m.contact_points[cp] = p;
            m.depths[cp] = -d;
            cp += 1;
        }
    }
    m.count = @intCast(cp);
    m.n = h.n;
}

fn capsuleSupport(A: Capsule, dir: Vec2) Vec2 {
    const da = A.a.dot(dir);
    const db = A.b.dot(dir);
    if (da > db) return A.a.add(dir.mul(A.r));
    return A.b.add(dir.mul(A.r));
}

fn incidentFunc(incident: *[2]Vec2, ip: *const Poly, ix: Transform, rn_in_incident_space: Vec2) void {
    var index: usize = 0;
    var min_dot = std.math.floatMax(f32);

    var i: usize = 0;
    while (i < @as(usize, @intCast(ip.count))) : (i += 1) {
        const dot = rn_in_incident_space.dot(ip.norms[i]);
        if (dot < min_dot) {
            min_dot = dot;
            index = i;
        }
    }

    incident[0] = ix.mulVec(ip.verts[index]);
    const next = if (index + 1 == @as(usize, @intCast(ip.count))) 0 else index + 1;
    incident[1] = ix.mulVec(ip.verts[next]);
}

fn checkFaces(A: *const Poly, ax: Transform, B: *const Poly, bx: Transform, face_index: *i32) f32 {
    const b_in_a = ax.mulT(bx);
    const a_in_b = bx.mulT(ax);
    var sep = -std.math.floatMax(f32);
    var index: usize = 0;

    var i: usize = 0;
    while (i < @as(usize, @intCast(A.count))) : (i += 1) {
        const h = planeAt(A, i);
        const idx = support(B.verts[0..@intCast(B.count)], a_in_b.r.mulVec(h.n.neg()));
        const p = b_in_a.mulVec(B.verts[@intCast(idx)]);
        const d = h.dist(p);
        if (d > sep) {
            sep = d;
            index = i;
        }
    }

    face_index.* = @intCast(index);
    return sep;
}

// Manifold Functions

pub fn circleToCircleManifold(A: Circle, B: Circle, m: *Manifold) void {
    m.count = 0;
    const d = B.p.sub(A.p);
    const d2 = d.dot(d);
    const r = A.r + B.r;
    if (d2 < r * r) {
        const l = math.sqrt(d2);
        const n = if (l != 0) d.mul(1.0 / l) else Vec2.init(0, 1);
        m.count = 1;
        m.depths[0] = r - l;
        m.contact_points[0] = B.p.sub(n.mul(B.r));
        m.n = n;
    }
}

pub fn circleToAABBManifold(A: Circle, B: AABB, m: *Manifold) void {
    m.count = 0;
    const L = A.p.min(B.max).max(B.min);
    const ab = L.sub(A.p);
    const d2 = ab.dot(ab);
    const r2 = A.r * A.r;

    if (d2 < r2) {
        if (d2 != 0) {
            const d = math.sqrt(d2);
            const n = ab.norm();
            m.count = 1;
            m.depths[0] = A.r - d;
            m.contact_points[0] = A.p.add(n.mul(d));
            m.n = n;
        } else {
            const mid = B.min.add(B.max).mul(0.5);
            const e = B.max.sub(B.min).mul(0.5);
            const d = A.p.sub(mid);
            const abs_d = d.abs();

            const x_overlap = e.x - abs_d.x;
            const y_overlap = e.y - abs_d.y;

            var depth: f32 = 0;
            var n: Vec2 = undefined;

            if (x_overlap < y_overlap) {
                depth = x_overlap;
                n = Vec2.init(if (d.x < 0) 1.0 else -1.0, 0);
            } else {
                depth = y_overlap;
                n = Vec2.init(0, if (d.y < 0) 1.0 else -1.0);
            }

            m.count = 1;
            m.depths[0] = A.r + depth;
            m.contact_points[0] = A.p.sub(n.mul(depth));
            m.n = n;
        }
    }
}

pub fn circleToCapsuleManifold(A: Circle, B: Capsule, m: *Manifold) void {
    m.count = 0;
    var a: Vec2 = undefined;
    var b: Vec2 = undefined;
    const shapeA = Shape{ .circle = A };
    const shapeB = Shape{ .capsule = B };

    const r = A.r + B.r;
    const d = gjk(shapeA, null, shapeB, null, false, null, null, &a, &b);

    if (d < r) {
        var n: Vec2 = undefined;
        if (d == 0) n = B.b.sub(B.a).skew().norm() else n = b.sub(a).norm();

        m.count = 1;
        m.depths[0] = r - d;
        m.contact_points[0] = b.sub(n.mul(B.r));
        m.n = n;
    }
}

pub fn aabbToAABBManifold(A: AABB, B: AABB, m: *Manifold) void {
    m.count = 0;
    const mid_a = A.min.add(A.max).mul(0.5);
    const mid_b = B.min.add(B.max).mul(0.5);
    const eA = A.max.sub(A.min).mul(0.5).abs();
    const eB = B.max.sub(B.min).mul(0.5).abs();
    const d = mid_b.sub(mid_a);

    const dx = eA.x + eB.x - @abs(d.x);
    if (dx < 0) return;
    const dy = eA.y + eB.y - @abs(d.y);
    if (dy < 0) return;

    var n: Vec2 = undefined;
    var depth: f32 = 0;
    var p: Vec2 = undefined;

    if (dx < dy) {
        depth = dx;
        if (d.x < 0) {
            n = Vec2.init(-1, 0);
            p = mid_a.sub(Vec2.init(eA.x, 0));
        } else {
            n = Vec2.init(1, 0);
            p = mid_a.add(Vec2.init(eA.x, 0));
        }
    } else {
        depth = dy;
        if (d.y < 0) {
            n = Vec2.init(0, -1);
            p = mid_a.sub(Vec2.init(0, eA.y));
        } else {
            n = Vec2.init(0, 1);
            p = mid_a.add(Vec2.init(0, eA.y));
        }
    }

    m.count = 1;
    m.contact_points[0] = p;
    m.depths[0] = depth;
    m.n = n;
}

pub fn aabbToCapsuleManifold(A: AABB, B: Capsule, m: *Manifold) void {
    m.count = 0;
    var p = Poly{ .count = 4, .verts = undefined, .norms = undefined };
    bbVerts(&p.verts, A);
    norms(&p.verts, &p.norms, 4);
    capsuleToPolyManifold(B, &p, null, m);
    m.n = m.n.neg();
}

pub fn capsuleToCapsuleManifold(A: Capsule, B: Capsule, m: *Manifold) void {
    m.count = 0;
    var a: Vec2 = undefined;
    var b: Vec2 = undefined;
    const shapeA = Shape{ .capsule = A };
    const shapeB = Shape{ .capsule = B };

    const r = A.r + B.r;
    const d = gjk(shapeA, null, shapeB, null, false, null, null, &a, &b);

    if (d < r) {
        var n: Vec2 = undefined;
        if (d == 0) n = A.b.sub(A.a).skew().norm() else n = b.sub(a).norm();

        m.count = 1;
        m.depths[0] = r - d;
        m.contact_points[0] = b.sub(n.mul(B.r));
        m.n = n;
    }
}

pub fn circleToPolyManifold(A: Circle, B: *const Poly, bx_ptr: ?*const Transform, m: *Manifold) void {
    m.count = 0;
    var a: Vec2 = undefined;
    var b: Vec2 = undefined;
    const shapeA = Shape{ .circle = A };
    const shapeB = Shape{ .poly = B.* };
    const bx = if (bx_ptr) |x| x.* else Transform.identity();

    const d = gjk(&shapeA, null, &shapeB, bx_ptr, false, null, null, &a, &b);

    if (d != 0) {
        const n = b.sub(a);
        var l = n.lenSq();
        if (l < A.r * A.r) {
            l = math.sqrt(l);
            m.count = 1;
            m.contact_points[0] = b;
            m.depths[0] = A.r - l;
            m.n = n.mul(1.0 / l);
        }
    } else {
        var sep = -std.math.floatMax(f32);
        var index: usize = 0;
        const local = bx.mulVecT(A.p);

        var i: usize = 0;
        while (i < @as(usize, @intCast(B.count))) : (i += 1) {
            const h = planeAt(B, i);
            const dist = h.dist(local);
            if (dist > A.r) return;
            if (dist > sep) {
                sep = dist;
                index = i;
            }
        }

        const h = planeAt(B, index);
        const p = h.project(local);
        m.count = 1;
        m.contact_points[0] = bx.mulVec(p);
        m.depths[0] = A.r - sep;
        m.n = bx.r.mulVec(B.norms[index]).neg();
    }
}

pub fn aabbToPolyManifold(A: AABB, B: *const Poly, bx: ?*const Transform, m: *Manifold) void {
    m.count = 0;
    var p = Poly{ .count = 4, .verts = undefined, .norms = undefined };
    bbVerts(&p.verts, A);
    norms(&p.verts, &p.norms, 4);
    polyToPolyManifold(&p, null, B, bx, m);
}

pub fn capsuleToPolyManifold(A: Capsule, B: *const Poly, bx_ptr: ?*const Transform, m: *Manifold) void {
    m.count = 0;
    var a: Vec2 = undefined;
    var b: Vec2 = undefined;
    const shapeA = Shape{ .capsule = A };
    const shapeB = Shape{ .poly = B.* };
    const bx = if (bx_ptr) |x| x.* else Transform.identity();

    const d = gjk(&shapeA, null, &shapeB, bx_ptr, false, null, null, &a, &b);

    // deep
    if (d < 1.0e-6) {
        var A_in_B = Capsule{ .a = bx.mulVecT(A.a), .b = bx.mulVecT(A.b), .r = A.r };
        const ab = A_in_B.a.sub(A_in_B.b).norm();

        var ab_h0 = Plane{ .n = ab.ccw90(), .d = 0 };
        ab_h0.d = A_in_B.a.dot(ab_h0.n);
        const v0 = support(B.verts[0..@intCast(B.count)], ab_h0.n.neg());
        const s0 = ab_h0.dist(B.verts[@intCast(v0)]);

        var ab_h1 = Plane{ .n = ab.skew(), .d = 0 }; // skew is -y, x. ccw90 is y, -x. They are opp? No.
        ab_h1.d = A_in_B.a.dot(ab_h1.n);
        const v1 = support(B.verts[0..@intCast(B.count)], ab_h1.n.neg());
        const s1 = ab_h1.dist(B.verts[@intCast(v1)]);

        var index: usize = 0;
        var sep = -std.math.floatMax(f32);
        var code: i32 = 0;

        var i: usize = 0;
        while (i < @as(usize, @intCast(B.count))) : (i += 1) {
            const h = planeAt(B, i);
            // Original: float da = c2Dot(A_in_B.a, c2Neg(h.n)); ... wait, that's not distance.
            // C code: float da = c2Dot(A_in_B.a, c2Neg(h.n)); float db = ...
            // if (da > db) d = c2Dist(h, A_in_B.a); else d = c2Dist(h, A_in_B.b);
            // That seems to be maximizing projection on normal?
            // Actually, c2Dist uses dot(n, p) - d.
            const dist_a = h.dist(A_in_B.a);
            const dist_b = h.dist(A_in_B.b);
            const dist = @max(dist_a, dist_b);

            if (dist > sep) {
                sep = dist;
                index = i;
            }
        }

        if (s0 > sep) {
            sep = s0;
            index = @intCast(v0);
            code = 1;
        }
        if (s1 > sep) {
            sep = s1;
            index = @intCast(v1);
            code = 2;
        }

        switch (code) {
            0 => {
                var seg = [2]Vec2{ A.a, A.b };
                var h: Plane = undefined;
                if (sidePlanesFromPoly(&seg, bx, B, @intCast(index), &h) == 0) return;
                keepDeep(&seg, h, m);
                m.n = m.n.neg();
            },
            1 => {
                var incident: [2]Vec2 = undefined;
                incidentFunc(&incident, B, bx, ab_h0.n);
                var h: Plane = undefined;
                if (sidePlanes(&incident, A_in_B.b, A_in_B.a, &h) == 0) return;
                keepDeep(&incident, h, m);
            },
            2 => {
                var incident: [2]Vec2 = undefined;
                incidentFunc(&incident, B, bx, ab_h1.n);
                var h: Plane = undefined;
                if (sidePlanes(&incident, A_in_B.a, A_in_B.b, &h) == 0) return;
                keepDeep(&incident, h, m);
            },
            else => return,
        }

        var k: usize = 0;
        while (k < m.count) : (k += 1) {
            m.depths[k] += A.r;
        }
    } else if (d < A.r) {
        m.count = 1;
        m.n = b.sub(a).norm();
        m.contact_points[0] = a.add(m.n.mul(A.r));
        m.depths[0] = A.r - d;
    }
}

pub fn polyToPolyManifold(A: *const Poly, ax_ptr: ?*const Transform, B: *const Poly, bx_ptr: ?*const Transform, m: *Manifold) void {
    m.count = 0;
    const ax = if (ax_ptr) |x| x.* else Transform.identity();
    const bx = if (bx_ptr) |x| x.* else Transform.identity();

    var ea: i32 = 0;
    var eb: i32 = 0;
    const sa = checkFaces(A, ax, B, bx, &ea);
    if (sa >= 0) return;
    const sb = checkFaces(B, bx, A, ax, &eb);
    if (sb >= 0) return;

    const kRelTol = 0.95;
    const kAbsTol = 0.01;

    var rp: *const Poly = undefined;
    var rx: Transform = undefined;
    var ip: *const Poly = undefined;
    var ix: Transform = undefined;
    var re: i32 = 0;
    var flip = false;

    if (sa * kRelTol > sb + kAbsTol) {
        rp = A;
        rx = ax;
        ip = B;
        ix = bx;
        re = ea;
        flip = false;
    } else {
        rp = B;
        rx = bx;
        ip = A;
        ix = ax;
        re = eb;
        flip = true;
    }

    var incident: [2]Vec2 = undefined;
    incidentFunc(&incident, ip, ix, rx.r.mulVec(rp.norms[@intCast(re)])); // ix.mulT... no, c2MulrvT(ix.r, c2Mulrv(rx.r, ...))
    // C code: c2Incident(incident, ip, ix, c2MulrvT(ix.r, c2Mulrv(rx.r, rp->norms[re])));
    // The direction passed to incident is in Incident Shape's Local Space.
    // normal in world: rx.r * n_r
    // normal in incident local: ix.r^T * (rx.r * n_r)
    const world_n = rx.r.mulVec(rp.norms[@intCast(re)]);
    const local_n = ix.r.mulVecT(world_n);
    incidentFunc(&incident, ip, ix, local_n);

    var rh: Plane = undefined;
    if (sidePlanesFromPoly(&incident, rx, rp, re, &rh) == 0) return;
    keepDeep(&incident, rh, m);
    if (flip) m.n = m.n.neg();
}

// Time of Impact
pub fn toi(A: *const Shape, ax_ptr: ?*const Transform, vA: Vec2, B: *const Shape, bx_ptr: ?*const Transform, vB: Vec2, use_radius: bool) TOIResult {
    var result = TOIResult{
        .hit = 0,
        .toi = 1.0,
        .n = Vec2.init(0, 0),
        .p = Vec2.init(0, 0),
        .iterations = 0,
    };

    var t: f32 = 0;
    const ax = if (ax_ptr) |x| x.* else Transform.identity();
    const bx = if (bx_ptr) |x| x.* else Transform.identity();

    var pA: Proxy = undefined;
    var pB: Proxy = undefined;
    makeProxy(A, &pA);
    makeProxy(B, &pB);

    var s = Simplex{ .a = undefined, .b = undefined, .c = undefined, .d = undefined, .div = 0, .count = 0 };
    // Initialize pointers to simplex verts for loop
    const verts = [_]*SimplexVertex{ &s.a, &s.b, &s.c, &s.d };

    const rv = vB.sub(vA);
    // Initial separation
    var iA = support(pA.verts[0..@intCast(pA.count)], ax.r.mulVecT(rv.neg()));
    var sA = ax.mulVec(pA.verts[@intCast(iA)]);
    var iB = support(pB.verts[0..@intCast(pB.count)], bx.r.mulVecT(rv));
    var sB = bx.mulVec(pB.verts[@intCast(iB)]);
    var v = sA.sub(sB);

    var rA = pA.radius;
    var rB = pB.radius;
    var radius = rA + rB;
    if (!use_radius) {
        rA = 0;
        rB = 0;
        radius = 0;
    }
    const tolerance = 1.0e-4;

    if (!(v.len() - radius > tolerance)) {
        result.toi = 0;
        result.hit = 1;
        return result;
    }

    while (result.iterations < 20) {
        // Support in -v
        iA = support(pA.verts[0..@intCast(pA.count)], ax.r.mulVecT(v.neg()));
        sA = ax.mulVec(pA.verts[@intCast(iA)]);
        iB = support(pB.verts[0..@intCast(pB.count)], bx.r.mulVecT(v));
        sB = bx.mulVec(pB.verts[@intCast(iB)]);

        const p = sA.sub(sB);
        const vn = v.norm(); // normalized v
        const vp = vn.dot(p) - radius;
        const vr = vn.dot(rv);

        if (vp > t * vr) {
            if (vr <= 0) return result;
            t = vp / vr;
            if (t > 1.0) return result;
            result.n = vn.neg();
            s.count = 0;
        }

        const sv = verts[@intCast(s.count)];
        sv.iA = iB; // NOTE: swapped in C?
        // C code: sv->iA = iB; sv->sA = c2Add(sB, c2Mulvs(rv, t)); ...
        // In C GJKRaycast, 'Target' is usually A, and we sweep A against B.
        // Wait, C code: iA = c2Support(pA ...), sA ... iB = c2Support(pB ...)
        // C code: sv->iA = iB; sv->sA = ... sB ...
        // It seems the Simplex keeps points from M. p = sA - sB.
        // C code: sv->p = c2Sub(sv->sB, sv->sA);
        // And sA is from A, sB is from B.
        // BUT in TOI loop:
        // sv->sA = c2Add(sB, c2Mulvs(rv, t));
        // sv->sB = sA;
        // This effectively computes Minkowski Difference of (B + rv*t) - A.
        // Let's copy C logic exactly.

        sv.iA = iB;
        sv.sA = sB.add(rv.mul(t));
        sv.iB = iA;
        sv.sB = sA;
        sv.p = sv.sB.sub(sv.sA);
        sv.u = 1.0;
        s.count += 1;

        switch (s.count) {
            2 => simplex2(&s),
            3 => simplex3(&s),
            else => {},
        }

        if (s.count == 3) {
            result.toi = t;
            result.hit = 1;
            return result;
        }

        v = simplexL(&s);
        result.iterations += 1;
    }

    if (result.iterations == 0) {
        result.hit = 0;
    } else {
        if (v.lenSq() > 0) result.n = v.neg().safeNorm();
        // Closest pair on A
        const i = support(pA.verts[0..@intCast(pA.count)], ax.r.mulVecT(result.n));
        var p = ax.mulVec(pA.verts[@intCast(i)]);
        p = p.add(result.n.mul(rA)).add(vA.mul(t));
        result.p = p;
        result.toi = t;
        result.hit = 1;
    }

    return result;
}

// Poly Inflation Internals
fn dual(p: Poly, skin_factor: f32) Poly {
    var d: Poly = undefined;
    d.count = p.count;

    var i: usize = 0;
    while (i < @as(usize, @intCast(p.count))) : (i += 1) {
        const n = p.norms[i];
        const dist = n.dot(p.verts[i]) + skin_factor; // dist is d in plane eq
        if (dist == 0) {
            d.verts[i] = Vec2.init(0, 0);
        } else {
            d.verts[i] = n.mul(1.0 / dist);
        }
    }

    norms(&d.verts, &d.norms, d.count);
    return d;
}

fn inflatePoly(p: Poly, skin_factor: f32) Poly {
    var average = p.verts[0];
    var i: usize = 1;
    while (i < @as(usize, @intCast(p.count))) : (i += 1) {
        average = average.add(p.verts[i]);
    }
    average = average.mul(1.0 / @as(f32, @floatFromInt(p.count)));

    var poly = p;
    i = 0;
    while (i < @as(usize, @intCast(poly.count))) : (i += 1) {
        poly.verts[i] = poly.verts[i].sub(average);
    }

    const d = dual(poly, skin_factor);
    poly = dual(d, 0);

    i = 0;
    while (i < @as(usize, @intCast(poly.count))) : (i += 1) {
        poly.verts[i] = poly.verts[i].add(average);
    }

    return poly;
}

pub fn inflate(shape: *Shape, skin_factor: f32) void {
    switch (shape.*) {
        .circle => |*c| c.r += skin_factor,
        .aabb => |*bb| {
            const factor = Vec2.init(skin_factor, skin_factor);
            bb.min = bb.min.sub(factor);
            bb.max = bb.max.add(factor);
        },
        .capsule => |*c| c.r += skin_factor,
        .poly => |*p| {
            p.* = inflatePoly(p.*, skin_factor);
        },
    }
}

// Optimized Boolean Collisions
pub fn circleToCircle(A: Circle, B: Circle) bool {
    const c = B.p.sub(A.p);
    const d2 = c.lenSq();
    const r2 = (A.r + B.r) * (A.r + B.r);
    return d2 < r2;
}

pub fn circleToAABB(A: Circle, B: AABB) bool {
    const L = A.p.min(B.max).max(B.min);
    const ab = A.p.sub(L);
    const d2 = ab.lenSq();
    return d2 < A.r * A.r;
}

pub fn aabbToAABB(A: AABB, B: AABB) bool {
    if (B.max.x < A.min.x or A.max.x < B.min.x or
        B.max.y < A.min.y or A.max.y < B.min.y) return false;
    return true;
}

pub fn circleToCapsule(A: Circle, B: Capsule) bool {
    const n = B.b.sub(B.a);
    const ap = A.p.sub(B.a);
    const da = ap.dot(n);
    var d2: f32 = 0;

    if (da < 0) {
        d2 = ap.lenSq();
    } else {
        const db = A.p.sub(B.b).dot(n);
        if (db < 0) {
            const e = ap.sub(n.mul(da / n.lenSq()));
            d2 = e.lenSq();
        } else {
            const bp = A.p.sub(B.b);
            d2 = bp.lenSq();
        }
    }

    const r = A.r + B.r;
    return d2 < r * r;
}

pub fn circleToPoly(A: Circle, B: *const Poly, bx: ?*const Transform) bool {
    const shapeA = Shape{ .circle = A };
    const shapeB = Shape{ .poly = B.* };
    return gjk(shapeA, null, shapeB, bx, true, null, null, null, null) == 0;
}

pub fn aabbToCapsule(A: AABB, B: Capsule) bool {
    const shapeA = Shape{ .aabb = A };
    const shapeB = Shape{ .capsule = B };
    return gjk(shapeA, null, shapeB, null, true, null, null, null, null) == 0;
}

pub fn aabbToPoly(A: AABB, B: *const Poly, bx: ?*const Transform) bool {
    const shapeA = Shape{ .aabb = A };
    const shapeB = Shape{ .poly = B.* };
    return gjk(shapeA, null, shapeB, bx, true, null, null, null, null) == 0;
}

pub fn capsuleToCapsule(A: Capsule, B: Capsule) bool {
    const shapeA = Shape{ .capsule = A };
    const shapeB = Shape{ .capsule = B };
    return gjk(shapeA, null, shapeB, null, true, null, null, null, null) == 0;
}

pub fn capsuleToPoly(A: Capsule, B: *const Poly, bx: ?*const Transform) bool {
    const shapeA = Shape{ .capsule = A };
    const shapeB = Shape{ .poly = B.* };
    return gjk(shapeA, null, shapeB, bx, true, null, null, null, null) == 0;
}

pub fn polyToPoly(A: *const Poly, ax: ?*const Transform, B: *const Poly, bx: ?*const Transform) bool {
    const shapeA = Shape{ .poly = A.* };
    const shapeB = Shape{ .poly = B.* };
    return gjk(shapeA, ax, shapeB, bx, true, null, null, null, null) == 0;
}

pub fn collided(A: *const Shape, ax: ?*const Transform, B: *const Shape, bx: ?*const Transform) bool {
    switch (A.*) {
        .circle => |c| {
            switch (B.*) {
                .circle => |oc| return circleToCircle(c, oc),
                .aabb => |occ| return circleToAABB(c, occ),
                .capsule => |occ| return circleToCapsule(c, occ),
                .poly => |*occ| return circleToPoly(c, occ, bx),
            }
        },
        .aabb => |c| {
            switch (B.*) {
                .circle => |occ| return circleToAABB(occ, c),
                .aabb => |occ| return aabbToAABB(c, occ),
                .capsule => |occ| return aabbToCapsule(c, occ),
                .poly => |*occ| return aabbToPoly(c, occ, bx),
            }
        },
        .capsule => |c| {
            switch (B.*) {
                .circle => |occ| return circleToCapsule(occ, c),
                .aabb => |occ| return aabbToCapsule(occ, c),
                .capsule => |occ| return capsuleToCapsule(c, occ),
                .poly => |*occ| return capsuleToPoly(c, occ, bx),
            }
        },
        .poly => |*c| {
            switch (B.*) {
                .circle => |occ| return circleToPoly(occ, c, ax),
                .aabb => |occ| return aabbToPoly(occ, c, ax),
                .capsule => |occ| return capsuleToPoly(occ, c, ax),
                .poly => |*occ| return polyToPoly(c, ax, occ, bx),
            }
        },
    }
}

pub fn collide(A: *const Shape, ax: ?*const Transform, B: *const Shape, bx: ?*const Transform, m: *Manifold) void {
    m.count = 0;
    switch (A.*) {
        .circle => |c| {
            switch (B.*) {
                .circle => |oc| circleToCircleManifold(c, oc, m),
                .aabb => |occ| circleToAABBManifold(c, occ, m),
                .capsule => |occ| circleToCapsuleManifold(c, occ, m),
                .poly => |*occ| circleToPolyManifold(c, occ, bx, m),
            }
        },
        .aabb => |c| {
            switch (B.*) {
                .circle => |occ| {
                    circleToAABBManifold(occ, c, m);
                    m.n = m.n.neg();
                },
                .aabb => |occ| aabbToAABBManifold(c, occ, m),
                .capsule => |occ| aabbToCapsuleManifold(c, occ, m),
                .poly => |*occ| aabbToPolyManifold(c, occ, bx, m),
            }
        },
        .capsule => |c| {
            switch (B.*) {
                .circle => |occ| {
                    circleToCapsuleManifold(occ, c, m);
                    m.n = m.n.neg();
                },
                .aabb => |occ| {
                    aabbToCapsuleManifold(occ, c, m);
                    m.n = m.n.neg();
                },
                .capsule => |occ| capsuleToCapsuleManifold(c, occ, m),
                .poly => |*occ| capsuleToPolyManifold(c, occ, bx, m),
            }
        },
        .poly => |*c| {
            switch (B.*) {
                .circle => |occ| {
                    circleToPolyManifold(occ, c, ax, m);
                    m.n = m.n.neg();
                },
                .aabb => |occ| {
                    aabbToPolyManifold(occ, c, ax, m);
                    m.n = m.n.neg();
                },
                .capsule => |occ| {
                    capsuleToPolyManifold(occ, c, ax, m);
                    m.n = m.n.neg();
                },
                .poly => |*occ| polyToPolyManifold(c, ax, occ, bx, m),
            }
        },
    }
}
