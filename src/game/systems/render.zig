const std = @import("std");
const ecs = @import("zflecs");
const C = @import("../components.zig");
const Engine = @import("../../engine/core.zig").Engine;
const input_mod = @import("../../engine/input.zig");
const pixel_mod = @import("../../engine/pixels.zig");
const Effect = @import("../../engine/effects.zig").Effect;
const physics = @import("physics.zig");

const LinkDrawEntry = struct {
    child_pos: C.Position,
    parent_pos: C.Position,
    child_r: f32,
    parent_r: f32,
    color: u32,
    effect: Effect,
    is_tail: bool,
    child_is_landable: bool,
    parent_is_landable: bool,
    landable_center_pos: ?C.Position,
};

fn drawEntityShape(engine: *Engine, pos: C.Position, col: C.Collider, color: u32, effect: Effect) void {
    switch (col) {
        .circle => |c| {
            pixel_mod.drawCircleFilled(engine, pos.x + c.p.x, pos.y + c.p.y, c.r, color, effect);
        },
        .box => |b| {
            const min_x: i32 = @intFromFloat(pos.x + b.min.x);
            const min_y: i32 = @intFromFloat(pos.y + b.min.y);
            const max_x: i32 = @intFromFloat(pos.x + b.max.x);
            const max_y: i32 = @intFromFloat(pos.y + b.max.y);
            const w: usize = @intCast(@max(0, max_x - min_x));
            const h: usize = @intCast(@max(0, max_y - min_y));
            pixel_mod.drawRect(engine, min_x, min_y, w, h, color, effect);
        },
    }
}

fn getColliderRadius(world: *ecs.world_t, entity: ecs.entity_t, fallback: f32) f32 {
    const col = ecs.get(world, entity, C.Collider) orelse return fallback;
    return switch (col.*) {
        .circle => |c| c.r,
        .box => |b| @min(b.max.x - b.min.x, b.max.y - b.min.y) * 0.5,
    };
}

fn findLandableCenterPos(world: *ecs.world_t, entity: ecs.entity_t) ?C.Position {
    const attached_id = ecs.id(C.AttachedTo);
    var idx: i32 = 0;
    while (idx < 8) : (idx += 1) {
        const raw_target = ecs.get_target(world, entity, attached_id, idx);
        if (raw_target == 0) break;
        const target = ecs.get_alive(world, raw_target);
        if (target == 0) continue;
        if (ecs.has_id(world, target, ecs.id(C.PlayerLandable))) {
            if (ecs.get(world, target, C.Position)) |p| {
                return p.*;
            }
        }
    }
    return null;
}

fn drawRenderQuery(world: *ecs.world_t, engine: *Engine, query: *ecs.query_t) void {
    var q_it = ecs.query_iter(world, query);
    while (ecs.query_next(&q_it)) {
        const positions = ecs.field(&q_it, C.Position, 0).?;
        const colliders = ecs.field(&q_it, C.Collider, 1).?;
        const renderables = ecs.field(&q_it, C.Renderable, 2).?;
        const ents = q_it.entities();

        for (positions, colliders, renderables, 0..) |pos, col, rend, i| {
            const color = pixel_mod.packColor(rend.color.r, rend.color.g, rend.color.b, rend.color.a);
            const effect = ecs.get(world, ents[i], Effect) orelse &Effect.none;
            drawEntityShape(engine, pos, col, color, effect.*);
        }
    }
}

pub fn render_system(it: *ecs.iter_t) void {
    const world = it.world;
    const engine = Engine.getEngine(world);
    const phys = ecs.singleton_get(world, C.PhysicsState) orelse return;
    const arena = engine.arena.allocator();

    // 1. Terrain (Ground boxes/circles)
    if (phys.render_ground_query) |ground_q| {
        var q_it = ecs.query_iter(world, ground_q);
        while (ecs.query_next(&q_it)) {
            const positions = ecs.field(&q_it, C.Position, 1).?;
            const colliders = ecs.field(&q_it, C.Collider, 2).?;
            const renderables = ecs.field(&q_it, C.Renderable, 3).?;
            const ents = q_it.entities();

            for (positions, colliders, renderables, 0..) |pos, col, rend, i| {
                const color = pixel_mod.packColor(rend.color.r, rend.color.g, rend.color.b, rend.color.a);
                const effect = ecs.get(world, ents[i], Effect) orelse &Effect.none;
                drawEntityShape(engine, pos, col, color, effect.*);
            }
        }
    }

    // 2. Collect AttachedTo links for jelly skins & player tail capsules
    const attachments_group = if (C.singletonGetSafe(world, C.PlayerAttachmentsGroup)) |g| g.entity else 0;
    const player_entity = if (C.singletonGetSafe(world, C.PlayerContainer)) |pc| pc.entity else 0;

    var links: std.ArrayList(LinkDrawEntry) = .empty;
    if (phys.attachment_query) |attach_q| {
        var a_it = ecs.query_iter(world, attach_q);
        while (ecs.query_next(&a_it)) {
            const pair_id = a_it.ids.?[0];
            const parent_id = ecs.get_alive(world, ecs.pair_second(pair_id));
            if (parent_id == 0) continue;

            const parent_pos = ecs.get(world, parent_id, C.Position) orelse continue;
            const child_positions = ecs.field(&a_it, C.Position, 1).?;
            const ents = a_it.entities();

            const parent_is_landable = ecs.has_id(world, parent_id, ecs.id(C.PlayerLandable));
            const raw_parent_r = getColliderRadius(world, parent_id, 4.0);
            const tail_parent_r = if (parent_id == player_entity) @min(raw_parent_r, 7.0) else raw_parent_r;

            for (child_positions, 0..) |child_pos, i| {
                const child_id = ents[i];
                const is_tail = attachments_group != 0 and ecs.has_pair(world, child_id, ecs.ChildOf, attachments_group);
                const child_is_landable = ecs.has_id(world, child_id, ecs.id(C.PlayerLandable));
                const child_r = getColliderRadius(world, child_id, 3.0);

                const rend = ecs.get(world, child_id, C.Renderable);
                const color = if (rend) |r|
                    pixel_mod.packColor(r.color.r, r.color.g, r.color.b, r.color.a)
                else
                    pixel_mod.packColor(255, 255, 255, 255);
                const effect = (ecs.get(world, child_id, Effect) orelse &Effect.none).*;

                const center_pos = if (!is_tail and !child_is_landable and !parent_is_landable)
                    findLandableCenterPos(world, child_id)
                else
                    null;

                links.append(arena, .{
                    .child_pos = child_pos,
                    .parent_pos = parent_pos.*,
                    .child_r = child_r,
                    .parent_r = if (is_tail) tail_parent_r else raw_parent_r,
                    .color = color,
                    .effect = effect,
                    .is_tail = is_tail,
                    .child_is_landable = child_is_landable,
                    .parent_is_landable = parent_is_landable,
                    .landable_center_pos = center_pos,
                }) catch {};
            }
        }
    }

    // 2a. Translucent jelly body fill
    const jelly_fill_color = pixel_mod.packColor(0, 185, 215, 105);
    for (links.items) |link| {
        if (link.landable_center_pos) |center_pos| {
            pixel_mod.drawTriangleFilledAlpha(
                engine,
                center_pos.x,
                center_pos.y,
                link.child_pos.x,
                link.child_pos.y,
                link.parent_pos.x,
                link.parent_pos.y,
                jelly_fill_color,
            );
        }
    }

    // 2b. Inter-jelly tethers & perimeter membrane capsules
    const tether_color = pixel_mod.packColor(190, 50, 80, 255);
    for (links.items) |link| {
        if (link.is_tail) continue;
        if (link.child_is_landable and link.parent_is_landable) {
            pixel_mod.drawCapsuleFilled(
                engine,
                link.parent_pos.x,
                link.parent_pos.y,
                6.0,
                link.child_pos.x,
                link.child_pos.y,
                6.0,
                tether_color,
                Effect.none,
            );
        } else if (!link.child_is_landable and !link.parent_is_landable) {
            pixel_mod.drawCapsuleFilled(
                engine,
                link.parent_pos.x,
                link.parent_pos.y,
                4.5,
                link.child_pos.x,
                link.child_pos.y,
                4.5,
                link.color,
                link.effect,
            );
        }
    }

    // 2c. Jelly PlayerLandable cores + any unlinked Verlet Renderables
    var v_it = ecs.query_iter(world, phys.verlet_query);
    while (ecs.query_next(&v_it)) {
        const positions = ecs.field(&v_it, C.Position, 0).?;
        const colliders = ecs.field(&v_it, C.Collider, 2) orelse continue;
        const ents = v_it.entities();

        for (positions, colliders, 0..) |pos, col, i| {
            const e = ents[i];
            const has_links = ecs.get_target(world, e, ecs.id(C.AttachedTo), 0) != 0;
            const is_landable = ecs.has_id(world, e, ecs.id(C.PlayerLandable));
            if (!is_landable and has_links) continue;

            const rend = ecs.get(world, e, C.Renderable) orelse continue;
            const color = pixel_mod.packColor(rend.color.r, rend.color.g, rend.color.b, rend.color.a);
            const effect = ecs.get(world, e, Effect) orelse &Effect.none;
            drawEntityShape(engine, pos, col, color, effect.*);
        }
    }

    // 3. Player tail tapered capsules
    for (links.items) |link| {
        if (!link.is_tail) continue;
        pixel_mod.drawCapsuleFilled(
            engine,
            link.parent_pos.x,
            link.parent_pos.y,
            link.parent_r,
            link.child_pos.x,
            link.child_pos.y,
            link.child_r,
            link.color,
            link.effect,
        );
    }

    // 4. Non-Ground, Non-Verlet actors (Player, Gun, Bullets) as crisp circles & boxes
    if (phys.render_actor_query) |actor_q| {
        drawRenderQuery(world, engine, actor_q);
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
    const input = ecs.singleton_get(world, input_mod.InputState) orelse return;
    if (!input.debug_mode) return;

    const pair_id = it.ids.?[0];
    const target_id = ecs.get_alive(world, ecs.pair_second(pair_id));
    if (target_id == 0) return;

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
