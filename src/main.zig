const std = @import("std");
const ecs = @import("zflecs");
const z2 = @import("zig_c2");

const engine_mod = @import("engine/core.zig");
const input_mod = @import("engine/input.zig");
const pixels_mod = @import("engine/pixels.zig");
const systems = @import("game/systems.zig");
const world_mod = @import("game/world.zig");
const C = @import("game/components.zig");

const HEIGHT: usize = 1440 / 2;
const WIDTH: usize = 2560 / 2;

pub fn main(init: std.process.Init) !void {
    var engine = try engine_mod.Engine.init(init.gpa, WIDTH, HEIGHT);
    defer engine.deinit();

    var input = input_mod.InputState{};
    defer input.deinit();

    pixels_mod.makeGradientSIMD(engine.sky_buffer, engine.width, engine.height);
    @memcpy(engine.background_buffer, engine.sky_buffer);
    @memcpy(engine.pixel_buffer, engine.background_buffer);

    const world = ecs.init();
    defer _ = ecs.fini(world);
    defer world_mod.deinit(world);

    ecs.set_ctx(world, &engine, dummy_free);
    try world_mod.setup_game(world, &engine);

    var time_ticks = engine_mod.Engine.getTicksMs();

    // Activate Flecs Explorer web console: https://www.flecs.dev/explorer?host=localhost:2771
    ecs.FlecsRestImport(world);
    const flecs_rest_id = ecs.lookup(world, "flecs.rest.Rest");
    const config = ecs.EcsRest{ .port = 2771 };
    _ = ecs.set_id(world, flecs_rest_id, flecs_rest_id, @sizeOf(ecs.EcsRest), &config);
    std.log.info("Web console available at https://www.flecs.dev/explorer?host=localhost:2771", .{});

    while (!input.quit_requested) {
        const dt = calculateDeltaTime(&time_ticks);
        engine.beginFrame();

        input.update();
        _ = ecs.singleton_set(world, input_mod.InputState, input);

        const mouse_cursor = ecs.lookup(world, "MouseCursor");
        if (input.active_input_method != .controller) {
            const logical = engine.windowToLogical(input.mouse_x, input.mouse_y);
            const target = C.AimTarget{
                .x = @floatFromInt(logical.x),
                .y = @floatFromInt(logical.y),
            };
            _ = ecs.singleton_set(world, C.AimTarget, target);
            if (mouse_cursor != 0) {
                _ = ecs.set(world, mouse_cursor, C.Position, .{ .x = target.x, .y = target.y });
            }
        }

        engine.restoreBackground();
        _ = ecs.progress(world, dt);

        const aim = ecs.singleton_get(world, C.AimTarget) orelse &C.AimTarget{ .x = 0.0, .y = 0.0 };
        const cursor_color = pixels_mod.packColor(255, 0, 0, 255);
        pixels_mod.drawCursor(&engine, @intFromFloat(aim.x), @intFromFloat(aim.y), 10, cursor_color);

        if (input.debug_mode) systems.render.debug_draw_colliders(world);

        engine.renderFrame(dt);

        if (input.reset) {
            world_mod.reset_game(world, &engine);
            input.reset = false;
        }

        engine.present();
    }
}

fn dummy_free(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

fn calculateDeltaTime(last_time: *u64) f32 {
    const now = engine_mod.Engine.getTicksMs();
    const dt = @as(f32, @floatFromInt(now - last_time.*)) / 1000.0;
    last_time.* = now;
    return @min(dt, 1.0 / 60.0);
}

test {
    _ = @import("engine/effects.zig");
    _ = @import("engine/pixels.zig");
    _ = systems;
    _ = world_mod;
}

test "zflecs world lifecycle and zoot_c2 normal direction" {
    const testing = std.testing;

    const world = ecs.init();
    defer _ = ecs.fini(world);
    ecs.COMPONENT(world, C.Position);

    const e = ecs.new_id(world);
    _ = ecs.set(world, e, C.Position, .{ .x = 12.0, .y = 34.0 });
    const pos = ecs.get(world, e, C.Position).?;
    try testing.expectEqual(@as(f32, 12.0), pos.x);
    try testing.expectEqual(@as(f32, 34.0), pos.y);

    var m: z2.Manifold = undefined;
    z2.circleToCircleManifold(
        .{ .p = .{ .x = 0, .y = 0 }, .r = 10 },
        .{ .p = .{ .x = 0, .y = 15 }, .r = 10 },
        &m,
    );
    try testing.expectEqual(@as(i32, 1), m.count);
    try testing.expectApproxEqAbs(@as(f32, 5.0), m.depths[0], 0.001);
    try testing.expect(m.n.y > 0.99);
}
