const SDL = @import("sdl2");
const ecs = @import("zflecs");

pub const Position = struct { x: f32, y: f32 };
pub const Velocity = struct { x: f32, y: f32 };
pub const Rectangle = struct { w: f32, h: f32, color: SDL.Color };

pub const Box = struct { size: usize };

pub const Target = struct { x: f32, y: f32 };

// tag!
pub const Bullet = struct { _dummy: u8 };
pub const Player = struct { _dummy: u8 };
pub const Ground = struct { _dummy: u8 };

// singletons for easy access

pub const BulletsGroup = struct {
    entity: ecs.entity_t,
};

pub const PlayerContainer = struct {
    entity: ecs.entity_t,
};
