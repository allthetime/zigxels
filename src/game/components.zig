const SDL = @import("sdl2");
const ecs = @import("zflecs");
const c2 = @import("zig_c2");

pub const Position = struct { x: f32, y: f32 };
pub const Velocity = struct { x: f32, y: f32 };

pub const Renderable = struct { color: SDL.Color };

pub const Collider = union(enum) {
    box: c2.AABB,
    circle: c2.Circle,
};

pub const Target = struct { x: f32, y: f32 };

// tag!
pub const Bullet = struct {};
pub const Player = struct {};
pub const Gun = struct {};
pub const Ground = struct {};
pub const PhysicsBody = struct {};

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
