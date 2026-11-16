pub const physics = @import("systems/physics.zig");
pub const player = @import("systems/player.zig");
pub const weapons = @import("systems/weapons.zig");
pub const verlet = @import("systems/verlet.zig");
pub const render = @import("systems/render.zig");

test {
    _ = physics;
    _ = player;
    _ = weapons;
    _ = verlet;
    _ = render;
}
