const ecs = @import("zflecs");
const C = @import("../components.zig");
const Engine = @import("../../engine/core.zig").Engine;
const pixel_mod = @import("../../engine/pixels.zig");
const Effect = @import("../../engine/effects.zig").Effect;
const physics = @import("physics.zig");

pub fn render_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    colliders: []C.Collider,
    renderables: []C.Renderable,
) void {
    const engine = Engine.getEngine(it.world);
    const ents = it.entities();

    for (positions, colliders, renderables, 0..) |pos, col, rend, i| {
        const aabb = physics.getWorldAABB(pos, col);

        const min_x: i32 = @intFromFloat(aabb.min.x);
        const min_y: i32 = @intFromFloat(aabb.min.y);
        const max_x: i32 = @intFromFloat(aabb.max.x);
        const max_y: i32 = @intFromFloat(aabb.max.y);

        const w: usize = @intCast(@max(0, max_x - min_x));
        const h: usize = @intCast(@max(0, max_y - min_y));

        const color = pixel_mod.packColor(rend.color.r, rend.color.g, rend.color.b, rend.color.a);
        const effect = ecs.get(it.world, ents[i], Effect) orelse &Effect.none;

        pixel_mod.drawRect(engine, min_x, min_y, w, h, color, effect.*);
    }
}

/// Stamp effect flags into the effect_buffer for invisible effect zone entities.
pub fn effect_zone_system(
    it: *ecs.iter_t,
    positions: []C.Position,
    colliders: []C.Collider,
    effects: []Effect,
) void {
    const engine = Engine.getEngine(it.world);

    for (positions, colliders, effects) |pos, col, fx| {
        const aabb = physics.getWorldAABB(pos, col);
        const min_x: i32 = @intFromFloat(aabb.min.x);
        const min_y: i32 = @intFromFloat(aabb.min.y);
        const max_x: i32 = @intFromFloat(aabb.max.x);
        const max_y: i32 = @intFromFloat(aabb.max.y);
        const w: usize = @intCast(@max(0, max_x - min_x));
        const h: usize = @intCast(@max(0, max_y - min_y));

        pixel_mod.drawEffectOnly(engine, min_x, min_y, w, h, fx, 20);
    }
}

pub fn draw_attached_constraints_system(it: *ecs.iter_t) void {
    const world = it.world;
    const pair_id = it.ids.?[0];
    const target_id = ecs.pair_second(pair_id);
    const positions = ecs.field(it, C.Position, 1).?;
    const engine = Engine.getEngine(world);

    const parent_pos = ecs.get(world, target_id, C.Position) orelse return;
    const color = pixel_mod.packColor(100, 100, 255, 255);

    for (positions) |pos| {
        pixel_mod.drawLinePixels(engine, pos.x, pos.y, parent_pos.x, parent_pos.y, color);
    }
}

fn drawCollidersSlice(positions: []C.Position, colliders: []C.Collider, engine: *Engine, color: u32) void {
    for (positions, colliders) |p, col| {
        switch (col) {
            .circle => |c| {
                pixel_mod.drawCirclePixels(engine, p.x + c.p.x, p.y + c.p.y, c.r, color);
            },
            .box => |b| {
                const min_x = p.x + b.min.x;
                const min_y = p.y + b.min.y;
                const max_x = p.x + b.max.x;
                const max_y = p.y + b.max.y;
                pixel_mod.drawLinePixels(engine, min_x, min_y, max_x, min_y, color);
                pixel_mod.drawLinePixels(engine, max_x, min_y, max_x, max_y, color);
                pixel_mod.drawLinePixels(engine, max_x, max_y, min_x, max_y, color);
                pixel_mod.drawLinePixels(engine, min_x, max_y, min_x, min_y, color);
            },
        }
    }
}

pub fn debug_draw_colliders(world: *ecs.world_t) void {
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;
    const engine = Engine.getEngine(world);
    const debug_red = pixel_mod.packColor(255, 0, 0, 255);

    var q_it = ecs.query_iter(world, phys.collider_query);

    while (ecs.query_next(&q_it)) {
        const positions = ecs.field(&q_it, C.Position, 0).?;
        const colliders = ecs.field(&q_it, C.Collider, 1).?;
        drawCollidersSlice(positions, colliders, engine, debug_red);
    }
}
