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

// Cached queries for physics and debug systems
pub const PhysicsState = struct {
    ground_query: *ecs.query_t,
    verlet_query: *ecs.query_t,
    player_landable_query: *ecs.query_t,
    collider_query: *ecs.query_t,
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
