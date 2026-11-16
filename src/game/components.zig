const std = @import("std");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Position = struct { x: f32, y: f32 };
pub const Velocity = struct { x: f32, y: f32 };

pub const Renderable = struct { color: Color };

pub const Collider = union(enum) {
    box: c2.AABB,
    circle: c2.Circle,
};

pub const AimTarget = struct { x: f32, y: f32 };

pub const RecoilImpulse = struct { x: f32 = 0.0 };

pub const Gun = struct {
    cooldown: f32 = 0.0,
    fire_rate: f32 = 0.1,
    bullet_speed: f32 = 1000.0,
    recoil: f32 = 210.0,
    was_pressing: bool = false,
};

pub const ReservoirMaterial = enum(u8) {
    none = 0,
    purple = 1,
    water = 2,
};

pub const LiquidReservoir = struct {
    amount: u32 = 0,
    capacity: u32 = 80,
    material: ReservoirMaterial = .none,
    has_drunk_once: bool = false,
    drink_cooldown: f32 = 0.0,
    dry_push_cooldown: f32 = 0.0,
    dry_push_rate: f32 = 0.35,
    dry_push_recoil: f32 = 240.0,
    shot_cost: u32 = 2,
    shots_fired: u32 = 0,

    pub fn hasAmmo(self: LiquidReservoir) bool {
        return self.material != .none and self.amount >= self.shot_cost;
    }

    pub fn fillFraction(self: LiquidReservoir) f32 {
        if (self.capacity == 0) return 0.0;
        return std.math.clamp(
            @as(f32, @floatFromInt(self.amount)) / @as(f32, @floatFromInt(self.capacity)),
            0.0,
            1.0,
        );
    }

    pub fn tryConsumeForShot(self: *LiquidReservoir) bool {
        if (!self.hasAmmo()) return false;
        self.amount -= self.shot_cost;
        self.shots_fired += 1;
        if (self.amount == 0) {
            self.material = .none;
        }
        return true;
    }

    pub fn addLiquid(self: *LiquidReservoir, mat: ReservoirMaterial, units: u32) u32 {
        if (mat == .none or units == 0) return 0;
        if (self.amount >= self.capacity) return 0;
        if (self.material == .none or self.material == mat) {
            const space = self.capacity - self.amount;
            const added = @min(space, units);
            self.amount += added;
            if (added > 0) {
                self.material = mat;
                self.has_drunk_once = true;
            }
            return added;
        }
        return 0;
    }

    pub fn refillFull(self: *LiquidReservoir, mat: ReservoirMaterial) void {
        if (mat == .none) return;
        self.material = mat;
        self.amount = self.capacity;
        self.has_drunk_once = true;
        self.dry_push_cooldown = 0.0;
    }
};

pub const ExplosionParticle = struct {
    lifetime: f32,
    color: u32,
};

// Tags
pub const Bullet = struct {};
pub const Player = struct {};
pub const Ground = struct {};
pub const Destroyable = struct {};
pub const EffectZone = struct {}; // Invisible entity that stamps GPU effect flags
pub const PlayerLandable = struct {};

pub const PhysicsBody = struct {
    /// Restitution (bounciness) of the physics body
    restitution: f32 = 0.9,
    /// Friction of the physics body
    friction: f32 = 0.99,
    prev_x: f32 = 0.0,
    prev_y: f32 = 0.0,
    has_prev: bool = false,
};

// Group singletons for ownership and reset lifecycle
pub const GroundGroup = struct {
    entity: ecs.entity_t,
};

pub const BulletsGroup = struct {
    entity: ecs.entity_t,
};

pub const CreaturesGroup = struct {
    entity: ecs.entity_t,
};

pub const PlayerAttachmentsGroup = struct {
    entity: ecs.entity_t,
};

pub const PlayerContainer = struct {
    entity: ecs.entity_t,
};

pub const GamePipelines = struct {
    sim: ecs.entity_t,
    render: ecs.entity_t,
};

pub const FrameMetrics = struct {
    fixed_steps: u32 = 0,
    dropped_excess_time: bool = false,
    fps: f32 = 0.0,
    frame_dt_ms: f32 = 0.0,
    update_ms: f32 = 0.0,
    render_cpu_ms: f32 = 0.0,
    render_gl_ms: f32 = 0.0,

    bullet_count: u32 = 0,
    ground_count: u32 = 0,
    verlet_count: u32 = 0,
    explosion_count: u32 = 0,

    material_active_cells: u32 = 0,
    material_rock_cells: u32 = 0,
    material_sand_cells: u32 = 0,
    material_liquid_cells: u32 = 0,

    physics_checks: u32 = 0,
    physics_hits: u32 = 0,
    verlet_ground_checks: u32 = 0,
    verlet_ground_hits: u32 = 0,
    verlet_self_checks: u32 = 0,
    verlet_self_hits: u32 = 0,
    verlet_bullet_checks: u32 = 0,
    verlet_bullet_hits: u32 = 0,

    pub fn resetPerFrame(self: *FrameMetrics) void {
        self.fixed_steps = 0;
        self.dropped_excess_time = false;
        self.frame_dt_ms = 0.0;
        self.update_ms = 0.0;
        self.render_cpu_ms = 0.0;
        self.render_gl_ms = 0.0;
        self.physics_checks = 0;
        self.physics_hits = 0;
        self.verlet_ground_checks = 0;
        self.verlet_ground_hits = 0;
        self.verlet_self_checks = 0;
        self.verlet_self_hits = 0;
        self.verlet_bullet_checks = 0;
        self.verlet_bullet_hits = 0;
    }

    pub fn totalCollisionChecks(self: FrameMetrics) u32 {
        return self.physics_checks + self.verlet_ground_checks + self.verlet_self_checks + self.verlet_bullet_checks;
    }

    pub fn totalCollisionHits(self: FrameMetrics) u32 {
        return self.physics_hits + self.verlet_ground_hits + self.verlet_self_hits + self.verlet_bullet_hits;
    }
};

// Cached queries for physics, rendering, and debug systems
pub const PhysicsState = struct {
    ground_query: ?*ecs.query_t = null,
    verlet_query: *ecs.query_t,
    player_landable_query: *ecs.query_t,
    collider_query: *ecs.query_t,
    attachment_query: ?*ecs.query_t = null,
    reach_query: ?*ecs.query_t = null,
    bullet_query: ?*ecs.query_t = null,
    explosion_query: ?*ecs.query_t = null,
    render_actor_query: ?*ecs.query_t = null,
};

// Verlet / IK components
pub const VerletState = struct {
    old_x: f32,
    old_y: f32,
    friction: f32 = 0.95, // 1.0 = vacuum, <1.0 = damping
};

pub const AttachedTo = struct {
    dist: f32 = 0.0,
    stiffness: f32 = 1.0,
};

pub const ReachTowards = struct {
    stiffness: f32 = 1.0,
};

pub fn singletonGetSafe(world: *ecs.world_t, comptime T: type) ?*const T {
    if (ecs.id(T) == 0) return null;
    return ecs.singleton_get(world, T);
}

pub fn singletonGetMutSafe(world: *ecs.world_t, comptime T: type) ?*T {
    if (ecs.id(T) == 0) return null;
    return ecs.singleton_get_mut(world, T);
}
