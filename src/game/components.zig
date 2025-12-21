const SDL = @import("sdl2");

pub const Position = struct { x: f32, y: f32 };
pub const Velocity = struct { x: f32, y: f32 };
pub const Rectangle = struct { w: f32, h: f32, color: SDL.Color };
pub const Target = struct { x: f32, y: f32 };
