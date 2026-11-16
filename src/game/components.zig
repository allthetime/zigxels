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
    recoil: f32 = 100.0,
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
pub const GroundGrid = struct {};
pub const PlayerLandable = struct {};

pub const PhysicsBody = struct {
    /// Restitution (bounciness) of the physics body
    restitution: f32 = 0.9,
    /// Friction of the physics body
    friction: f32 = 0.99,
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
    frame_dt_ms: f32 = 0.0,
    update_ms: f32 = 0.0,
    render_cpu_ms: f32 = 0.0,
    render_gl_ms: f32 = 0.0,

    bullet_count: u32 = 0,
    ground_count: u32 = 0,
    verlet_count: u32 = 0,
    explosion_count: u32 = 0,

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
    ground_query: *ecs.query_t,
    verlet_query: *ecs.query_t,
    player_landable_query: *ecs.query_t,
    collider_query: *ecs.query_t,
    attachment_query: ?*ecs.query_t = null,
    reach_query: ?*ecs.query_t = null,
    bullet_query: ?*ecs.query_t = null,
    explosion_query: ?*ecs.query_t = null,
    render_ground_query: ?*ecs.query_t = null,
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
