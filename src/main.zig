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

pub const FIXED_DT: f32 = 1.0 / 120.0;
pub const MAX_STEPS_PER_FRAME: usize = 8;

pub const FixedStepAccumulator = struct {
    accumulator: f32 = 0.0,

    pub const StepResult = struct {
        steps: usize,
        dropped_excess: bool,
    };

    pub fn advance(self: *FixedStepAccumulator, raw_dt: f32) StepResult {
        if (!std.math.isFinite(raw_dt) or raw_dt <= 0.0) {
            return .{ .steps = 0, .dropped_excess = false };
        }

        self.accumulator += raw_dt;
        var steps: usize = 0;
        while (self.accumulator >= FIXED_DT and steps < MAX_STEPS_PER_FRAME) {
            self.accumulator -= FIXED_DT;
            steps += 1;
        }

        var dropped = false;
        if (steps >= MAX_STEPS_PER_FRAME and self.accumulator >= FIXED_DT) {
            self.accumulator = 0.0;
            dropped = true;
        }

        return .{ .steps = steps, .dropped_excess = dropped };
    }

    pub fn reset(self: *FixedStepAccumulator) void {
        self.accumulator = 0.0;
    }
};

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

    var last_time_ns = engine_mod.Engine.getTicksNs();
    var step_accum = FixedStepAccumulator{};
    var last_title_update_ns: u64 = last_time_ns;
    var last_log_ns: u64 = last_time_ns;
    var smoothed_dt: f32 = 1.0 / 60.0;

    // Activate Flecs Explorer web console: https://www.flecs.dev/explorer?host=localhost:2771
    ecs.FlecsRestImport(world);
    const flecs_rest_id = ecs.lookup(world, "flecs.rest.Rest");
    const config = ecs.EcsRest{ .port = 2771 };
    _ = ecs.set_id(world, flecs_rest_id, flecs_rest_id, @sizeOf(ecs.EcsRest), &config);
    std.log.info("Web console available at https://www.flecs.dev/explorer?host=localhost:2771", .{});

    const pipelines = ecs.singleton_get(world, C.GamePipelines).?.*;

    while (!input.quit_requested) {
        const frame_dt = measureDeltaTime(&last_time_ns);
        engine.beginFrame();

        const prev_debug = input.debug_mode;
        input.update();
        _ = ecs.singleton_set(world, input_mod.InputState, input);

        if (input.reset) {
            world_mod.reset_game(world, &engine);
            input.reset = false;
            step_accum.reset();
        }
        if (input.refill) {
            world_mod.refill_player_liquid(world);
            input.refill = false;
        }

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

        if (frame_dt > 0.0001 and frame_dt < 0.5) {
            smoothed_dt = smoothed_dt * 0.9 + frame_dt * 0.1;
        }

        if (ecs.singleton_get_mut(world, C.FrameMetrics)) |metrics| {
            metrics.resetPerFrame();
            metrics.frame_dt_ms = frame_dt * 1000.0;
            metrics.fps = if (smoothed_dt > 0.0001) 1.0 / smoothed_dt else 0.0;
        }

        const step_plan = step_accum.advance(frame_dt);
        if (step_plan.dropped_excess) {
            std.log.warn("Simulation catch-up cap ({d} steps) reached; dropping excess accumulated time", .{MAX_STEPS_PER_FRAME});
        }

        const flecs_dt = @min(frame_dt, 0.25);
        _ = ecs.frame_begin(world, flecs_dt);

        const sim_start_ns = engine_mod.Engine.getTicksNs();
        for (0..step_plan.steps) |_| {
            ecs.run_pipeline(world, pipelines.sim, FIXED_DT);
        }
        const sim_end_ns = engine_mod.Engine.getTicksNs();

        const render_cpu_start_ns = sim_end_ns;
        engine.restoreBackground();
        ecs.run_pipeline(world, pipelines.render, flecs_dt);

        const aim = ecs.singleton_get(world, C.AimTarget) orelse &C.AimTarget{ .x = 0.0, .y = 0.0 };
        const cursor_color = pixels_mod.packColor(255, 0, 0, 255);
        pixels_mod.drawCursor(&engine, @intFromFloat(aim.x), @intFromFloat(aim.y), 10, cursor_color);

        if (input.debug_mode) systems.render.debug_draw_colliders(world);
        const render_cpu_end_ns = engine_mod.Engine.getTicksNs();

        ecs.frame_end(world);

        const gl_start_ns = engine_mod.Engine.getTicksNs();
        engine.renderFrame(flecs_dt);
        const gl_end_ns = engine_mod.Engine.getTicksNs();

        if (input.debug_mode) {
            world_mod.updateEntityCounts(world);
        }
        if (ecs.singleton_get_mut(world, C.FrameMetrics)) |metrics| {
            metrics.fixed_steps = @intCast(step_plan.steps);
            metrics.dropped_excess_time = step_plan.dropped_excess;
            metrics.update_ms = nsToMs(sim_end_ns -| sim_start_ns);
            metrics.render_cpu_ms = nsToMs(render_cpu_end_ns -| render_cpu_start_ns);
            metrics.render_gl_ms = nsToMs(gl_end_ns -| gl_start_ns);

            if (input.debug_mode) {
                if (!prev_debug) {
                    logDebugMetrics(metrics.*);
                    last_log_ns = gl_end_ns;
                    last_title_update_ns = 0;
                }
                if (gl_end_ns -| last_title_update_ns >= 250_000_000) {
                    var title_buf: [240]u8 = undefined;
                    if (std.fmt.bufPrint(
                        title_buf[0 .. title_buf.len - 1],
                        "PIXELS | fps:{d:.0} steps:{d} upd:{d:.2}ms cpu:{d:.2}ms gl:{d:.2}ms | ents(B:{d} V:{d} E:{d}) mat(act:{d} liq:{d} sand:{d}) | col:{d}/{d}",
                        .{
                            metrics.fps,
                            metrics.fixed_steps,
                            metrics.update_ms,
                            metrics.render_cpu_ms,
                            metrics.render_gl_ms,
                            metrics.bullet_count,
                            metrics.verlet_count,
                            metrics.explosion_count,
                            metrics.material_active_cells,
                            metrics.material_liquid_cells,
                            metrics.material_sand_cells,
                            metrics.totalCollisionHits(),
                            metrics.totalCollisionChecks(),
                        },
                    )) |written| {
                        title_buf[written.len] = 0;
                        engine.setWindowTitle(title_buf[0..written.len :0]);
                    } else |_| {}
                    last_title_update_ns = gl_end_ns;
                }
                if (gl_end_ns -| last_log_ns >= 1_000_000_000) {
                    logDebugMetrics(metrics.*);
                    last_log_ns = gl_end_ns;
                }
            } else if (prev_debug) {
                engine.setWindowTitle("PIXELS");
            }
        }

        engine.present();
    }
}

fn nsToMs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / 1_000_000.0;
}

fn logDebugMetrics(m: C.FrameMetrics) void {
    std.log.info(
        "perf: fps={d:.1} steps={d} dt={d:.2}ms upd={d:.2}ms render_cpu={d:.2}ms render_gl={d:.2}ms | ents(bullets={d} verlet={d} explosions={d}) mat(act={d} rock={d} sand={d} liq={d}) | col(hits={d}/checks={d} phys={d}/{d} vg={d}/{d} vs={d}/{d} vb={d}/{d})",
        .{
            m.fps,
            m.fixed_steps,
            m.frame_dt_ms,
            m.update_ms,
            m.render_cpu_ms,
            m.render_gl_ms,
            m.bullet_count,
            m.verlet_count,
            m.explosion_count,
            m.material_active_cells,
            m.material_rock_cells,
            m.material_sand_cells,
            m.material_liquid_cells,
            m.totalCollisionHits(),
            m.totalCollisionChecks(),
            m.physics_hits,
            m.physics_checks,
            m.verlet_ground_hits,
            m.verlet_ground_checks,
            m.verlet_self_hits,
            m.verlet_self_checks,
            m.verlet_bullet_hits,
            m.verlet_bullet_checks,
        },
    );
}

fn dummy_free(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

fn measureDeltaTime(last_time_ns: *u64) f32 {
    const now = engine_mod.Engine.getTicksNs();
    const elapsed_ns = now -| last_time_ns.*;
    last_time_ns.* = now;
    return @as(f32, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
}

test {
    _ = @import("engine/effects.zig");
    _ = @import("engine/pixels.zig");
    _ = @import("game/material_world.zig");
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

test "FixedStepAccumulator runs 0..N steps at 1/120s and drops excess on stall" {
    const testing = std.testing;
    var accum = FixedStepAccumulator{};

    // 240Hz frame (~4.16ms): 0 steps on first frame, 1 step on second frame
    const r1 = accum.advance(1.0 / 240.0);
    try testing.expectEqual(@as(usize, 0), r1.steps);
    try testing.expect(!r1.dropped_excess);

    const r2 = accum.advance(1.0 / 240.0);
    try testing.expectEqual(@as(usize, 1), r2.steps);
    try testing.expect(!r2.dropped_excess);

    // 60Hz frame: 2 steps
    accum.reset();
    const r60 = accum.advance(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 2), r60.steps);
    try testing.expect(!r60.dropped_excess);

    // 250ms stall: capped at MAX_STEPS_PER_FRAME (8) and excess dropped cleanly
    accum.reset();
    const r_stall = accum.advance(0.25);
    try testing.expectEqual(MAX_STEPS_PER_FRAME, r_stall.steps);
    try testing.expect(r_stall.dropped_excess);
    try testing.expectEqual(@as(f32, 0.0), accum.accumulator);
}
