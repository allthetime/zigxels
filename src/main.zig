const std = @import("std");
const SDL = @import("sdl2");
const ecs = @import("zflecs");

const c = @cImport({
    @cInclude("stdio.h");
});

const engine_mod = @import("engine/core.zig");
const input_mod = @import("engine/input.zig");
const pixels_mod = @import("engine/pixels.zig");
const game = @import("game/systems.zig");
const components = @import("game/components.zig");

// physics
const Position = components.Position;
const Velocity = components.Velocity;
const Target = components.Target;
const Box = components.Box; // rendery

// render
const Rectangle = components.Rectangle;

// tags
const Bullet = components.Bullet;
const Player = components.Player;
const Ground = components.Ground;

// groups
const BulletsGroup = components.BulletsGroup;

fn usize_to_f32(i: usize) f32 {
    return @as(f32, @floatFromInt(i));
}

pub fn main() !void {
    var engine = try engine_mod.Engine.init(640, 480);
    defer engine.deinit();

    var input = input_mod.InputState{};

    // Basic test to see if it works
    const gravity = c.cpv(0, -100);
    const space = c.cpSpaceNew();
    defer c.cpSpaceFree(space);

    c.cpSpaceSetGravity(space, gravity);

    std.debug.print("Chipmunk Space initialized with gravity y: {d}\n", .{c.cpSpaceGetGravity(space).y});

    // Fill pixel buffer with a gradient
    pixels_mod.makeGradient(engine.pixel_buffer, engine.width, engine.height, null);

    const world = ecs.init();
    defer _ = ecs.fini(world);

    ecs.set_ctx(world, &engine, dummy_free);
    setup_game(world, &engine);

    const box = ecs.new_entity(world, "Box");
    _ = ecs.set(world, box, Position, .{ .x = 400.0, .y = 300.0 });
    _ = ecs.set(world, box, Rectangle, .{ .w = 100.0, .h = 100.0, .color = SDL.Color{ .r = 0, .g = 255, .b = 0, .a = 255 } });

    var last_time = SDL.getTicks64();
    var cursor_size: f32 = 20.0;
    var shooting = false;

    // Bullets Group to parent all bullets for easy dismissal and effect

    const bullets_group = ecs.new_entity(world, "Bullets");
    // 3. Store it in the Singleton
    _ = ecs.singleton_set(world, components.BulletsGroup, .{ .entity = bullets_group });

    while (!input.quit_requested) {
        engine.beginFrame();
        input.update();

        _ = ecs.singleton_set(world, input_mod.InputState, input);

        const dt = calculateDeltaTime(&last_time);

        // Handle Mouse Press to Set Target
        if (input.is_pressing) {
            // _ = ecs.set(world, player, Target, .{ .x = @as(f32, @floatFromInt(input.mouse_x)), .y = @as(f32, @floatFromInt(input.mouse_y)) });
        }

        if (input.is_pressing) {
            //
            // how the fuck do i make "Bullet01"??
            //

            // if (!shooting) {
            if (true) {
                shooting = true;
                // bullet_count += 1;
                // const bname = std.fmt.bufPrintZ(&buff2, "Bullet{}", .{bullet_count}) catch unreachable;
                // std.debug.print("{s}\n", .{bname});

                // const null_terminated = try allocator.dupeZ(u8, bname);
                // defer allocator.free(null_terminated);

                const bullet = ecs.new_id(world);

                if (ecs.singleton_get(world, components.BulletsGroup)) |group| {
                    _ = ecs.add_pair(world, bullet, ecs.ChildOf, group.entity);
                }
                const p = ecs.lookup(world, "Player");
                const player_position = ecs.get(world, p, Position);
                if (player_position) |pp| {
                    _ = ecs.set(world, bullet, Bullet, .{ ._dummy = 0 });
                    _ = ecs.set(world, bullet, Box, .{ .size = 10 });
                    _ = ecs.set(world, bullet, Position, pp.*);

                    const mouse_x = @as(f32, @floatFromInt(input.mouse_x));
                    const mouse_y = @as(f32, @floatFromInt(input.mouse_y));
                    const dx = mouse_x - pp.x;
                    const dy = mouse_y - pp.y;
                    const dist = @sqrt(dx * dx + dy * dy);

                    var vx: f32 = 0;
                    var vy: f32 = 0;
                    if (dist > 0) {
                        vx = (dx / dist) * game.BULLET_SPEED;
                        vy = (dy / dist) * game.BULLET_SPEED;
                    }

                    _ = ecs.set(world, bullet, Velocity, .{ .x = vx, .y = vy });
                    _ = ecs.set(world, bullet, Rectangle, .{ .w = 20.0, .h = 20.0, .color = SDL.Color{ .r = 255, .g = 0, .b = 255, .a = 255 } });
                } else {}
            }
        } else {
            shooting = false;
        }
        // Update ECS (Physics/Logic/Render)

        // Clear & Draw Texture (Pixel Layer)
        try engine.renderer.setColorRGB(0xF7, 0xA4, 0x1D); // Background color
        try engine.renderer.clear();
        try engine.updateTexture();

        pixels_mod.makeGradient(engine.pixel_buffer, engine.width, engine.height, null);
        _ = ecs.progress(world, dt);
        // Render Cursor (Manual for now)
        const cursorSize = updateCursorSize(input.is_pressing, &cursor_size);
        try renderMouseCursor(engine.renderer, &input, cursorSize);

        if (input.reset) {
            // delete all bullets
            if (ecs.singleton_get(world, components.BulletsGroup)) |group| {
                // Delete everything linked to this parent
                ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
            }
            input.reset = false;
        }

        engine.renderer.present();
    }
}

fn dummy_free(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

fn calculateDeltaTime(last_time: *u64) f32 {
    const now = SDL.getTicks64();
    const dt = @as(f32, @floatFromInt(now - last_time.*)) / 1000.0;
    last_time.* = now;
    return dt;
}

fn updateCursorSize(pressing: bool, current: *f32) i32 {
    const target: f32 = if (pressing) 5 else 10;
    const delta = lerp_delta(current.*, target, 0.1);
    current.* += delta;
    return @as(i32, @intFromFloat(current.*));
}

fn lerp_delta(current: f32, target: f32, time: f32) f32 {
    return (target - current) * time;
}

fn renderMouseCursor(renderer: SDL.Renderer, input: *input_mod.InputState, size: i32) !void {
    try renderer.setDrawBlendMode(.blend);
    try renderer.setColorRGBA(0xff, 0x00, 0x00, 0xAA);
    try renderer.fillRect(.{
        .x = input.mouse_x - @divTrunc(size, 2),
        .y = input.mouse_y - @divTrunc(size, 2),
        .width = size,
        .height = size,
    });
}

pub fn setup_game(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    register_components(world);
    register_systems(world);
    spawn_initial_entities(world, engine);
}

fn register_components(world: *ecs.world_t) void {
    ecs.COMPONENT(world, input_mod.InputState);
    ecs.COMPONENT(world, Position);
    ecs.COMPONENT(world, Velocity);
    ecs.COMPONENT(world, Rectangle);
    ecs.COMPONENT(world, Target);
    ecs.COMPONENT(world, Bullet);
    ecs.COMPONENT(world, Player);
    ecs.COMPONENT(world, BulletsGroup);
    ecs.COMPONENT(world, Box);
    ecs.COMPONENT(world, Ground);
}

fn register_systems(world: *ecs.world_t) void {
    _ = ecs.ADD_SYSTEM_WITH_FILTERS(world, "player_input_logic", ecs.PreUpdate, game.player_input_system, &.{
        .{ .id = ecs.id(Player) },
    });

    _ = ecs.ADD_SYSTEM(world, "seek", ecs.OnUpdate, game.seek_system);
    _ = ecs.ADD_SYSTEM(world, "gravity", ecs.OnUpdate, game.gravity_system);
    _ = ecs.ADD_SYSTEM(world, "shoot", ecs.OnUpdate, game.shoot_bullet);

    // Separated Axis Movement & Collision
    _ = ecs.ADD_SYSTEM(world, "move_x", ecs.OnUpdate, game.move_x_system);
    _ = ecs.ADD_SYSTEM(world, "ground_collision_x", ecs.OnUpdate, game.ground_collision_x_system);
    _ = ecs.ADD_SYSTEM(world, "move_y", ecs.OnUpdate, game.move_y_system);
    _ = ecs.ADD_SYSTEM(world, "ground_collision_y", ecs.OnUpdate, game.ground_collision_y_system);

    _ = ecs.ADD_SYSTEM(world, "render", ecs.OnStore, game.render_rect_system);
    _ = ecs.ADD_SYSTEM(world, "pixel_boxer", ecs.OnStore, game.render_pixel_box);
}

fn spawn_initial_entities(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    const player = ecs.new_entity(world, "Player");
    _ = ecs.set(world, player, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 2.0 });
    _ = ecs.set(world, player, Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, Rectangle, .{ .w = 50.0, .h = 50.0, .color = SDL.Color{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    _ = ecs.set(world, player, Player, .{ ._dummy = 0 });
    _ = ecs.set(world, player, Box, .{ .size = 25 });

    const ground1 = ecs.new_entity(world, "Ground1");
    _ = ecs.set(world, ground1, Ground, .{ ._dummy = 0 });
    _ = ecs.set(world, ground1, Position, .{ .x = @as(f32, @floatFromInt(engine.width)) / 2.0, .y = @as(f32, @floatFromInt(engine.height)) / 1.5 });
    _ = ecs.set(world, ground1, Box, .{ .size = 25 });
}
