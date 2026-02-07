const SDL = @import("sdl2");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");
const std = @import("std");

pub const Position = struct { x: f32, y: f32 };
pub const Velocity = struct { x: f32, y: f32 };

pub const Renderable = struct { color: SDL.Color };

pub const Collider = union(enum) {
    box: c2.AABB,
    circle: c2.Circle,
};

pub const Target = struct { x: f32, y: f32 };

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

// tag!
pub const Bullet = struct {};
pub const Player = struct {};
pub const Ground = struct {};
pub const Destroyable = struct {};
pub const PhysicsBody = struct {
    restitution: f32 = 0.9,
    friction: f32 = 0.99,
};

// singletons for easy access

pub const BulletsGroup = struct {
    entity: ecs.entity_t,
};

pub const PlayerContainer = struct {
    entity: ecs.entity_t,
};

pub const PhysicsState = struct {
    ground_query: *ecs.query_t,
};
