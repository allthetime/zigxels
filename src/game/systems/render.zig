const std = @import("std");
const ecs = @import("zflecs");
const C = @import("../components.zig");
const mw = @import("../material_world.zig");
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
    const landable_id = ecs.id(C.PlayerLandable);
    var idx: i32 = 0;
    while (idx < 4) : (idx += 1) {
        const raw_target = ecs.get_target(world, entity, attached_id, idx);
        if (raw_target == 0) break;
        const target = ecs.get_alive(world, raw_target);
        if (target == 0) continue;
        if (ecs.has_id(world, target, landable_id)) {
            if (ecs.get(world, target, C.Position)) |p| {
                return p.*;
            }
        }
    }
    return null;
}

fn drawPlayerBodyWithReservoir(engine: *Engine, pos: C.Position, radius: f32, reservoir: ?*const C.LiquidReservoir) void {
    const outer_col = pixel_mod.packColor(225, 55, 75, 255);
    const cavity_col = pixel_mod.packColor(28, 24, 38, 255);
    pixel_mod.drawCircleFilled(engine, pos.x, pos.y, radius, outer_col, Effect.none);

    const inner_r = @max(2.0, radius - 3.5);
    pixel_mod.drawCircleFilled(engine, pos.x, pos.y, inner_r, cavity_col, Effect.none);

    const res = reservoir orelse return;
    const frac = res.fillFraction();
    if (frac <= 0.001) return;

    const fill_col = pixel_mod.packColor(205, 65, 255, 255);
    const surface_col = pixel_mod.packColor(240, 145, 255, 255);
    const fill_top_y = (pos.y + inner_r) - (2.0 * inner_r * frac);

    const bw_f: f32 = @floatFromInt(engine.width);
    const bh_f: f32 = @floatFromInt(engine.height);
    const y0_f = @max(0.0, @floor(@max(fill_top_y, pos.y - inner_r)));
    const y1_f = @min(bh_f, @ceil(pos.y + inner_r));
    if (y1_f <= y0_f) return;

    const start_y: usize = @intFromFloat(y0_f);
    const end_y: usize = @intFromFloat(y1_f);
    const r_sq = inner_r * inner_r;

    for (start_y..end_y) |py| {
        const sy = @as(f32, @floatFromInt(py)) + 0.5;
        if (sy < fill_top_y) continue;
        const dy = sy - pos.y;
        const rem_sq = r_sq - dy * dy;
        if (rem_sq < 0.0) continue;

        const half_w = @sqrt(rem_sq);
        const x0_f = @max(0.0, @ceil(pos.x - half_w - 0.5));
        const x1_f = @min(bw_f, @floor(pos.x + half_w - 0.5) + 1.0);
        if (x1_f <= x0_f) continue;

        const start_x: usize = @intFromFloat(x0_f);
        const end_x: usize = @intFromFloat(x1_f);
        const is_surface = (sy - fill_top_y) < 1.5 and frac < 0.98;
        const col = if (is_surface) surface_col else fill_col;
        const row = py * engine.width;
        @memset(engine.pixel_buffer[row + start_x .. row + end_x], col);
    }
}

fn drawHUD(world: *ecs.world_t, engine: *Engine) void {
    const pc = C.singletonGetSafe(world, C.PlayerContainer);
    const res = if (pc) |p| ecs.get(world, p.entity, C.LiquidReservoir) else null;
    const metrics = C.singletonGetSafe(world, C.FrameMetrics);

    const bar_x: i32 = 24;
    const bar_y: i32 = 22;
    const bar_w: usize = 168;
    const bar_h: usize = 16;

    pixel_mod.drawRect(engine, bar_x, bar_y, bar_w, bar_h, pixel_mod.packColor(20, 18, 28, 255), Effect.none);

    if (res) |r| {
        const frac = r.fillFraction();
        const fill_w: usize = @intFromFloat(@as(f32, @floatFromInt(bar_w - 4)) * frac);
        if (fill_w > 0) {
            pixel_mod.drawRect(engine, bar_x + 2, bar_y + 2, fill_w, bar_h - 4, pixel_mod.packColor(198, 62, 248, 255), Effect.none);
        }
        const border_col = if (r.hasAmmo())
            pixel_mod.packColor(235, 185, 255, 255)
        else
            pixel_mod.packColor(190, 90, 105, 255);
        pixel_mod.drawRectOutline(engine, bar_x, bar_y, bar_w, bar_h, border_col);

        var label_buf: [32]u8 = undefined;
        const label = if (r.amount == 0)
            "LIQUID: EMPTY"
        else
            std.fmt.bufPrint(&label_buf, "LIQUID: {d}/{d}", .{ r.amount, r.capacity }) catch "LIQUID";
        pixel_mod.drawPixelText(engine, bar_x + @as(i32, @intCast(bar_w)) + 12, bar_y + 1, 2, label, pixel_mod.packColor(245, 238, 255, 255));

        const hint: []const u8 = if (r.amount == 0)
            "DRINK PURPLE POOL  (CLICK=DRY PUSH  F=REFILL  R=RESET)"
        else
            "SHOOT PURPLE BLOBS  (F=REFILL  R=RESET)";
        const hint_col: u32 = if (r.amount == 0)
            pixel_mod.packColor(225, 185, 255, 255)
        else
            pixel_mod.packColor(235, 242, 250, 255);
        pixel_mod.drawPixelText(engine, bar_x, bar_y + 24, 2, hint, hint_col);
    }

    if (metrics) |m| {
        var fps_buf: [24]u8 = undefined;
        const fps_val: u32 = if (std.math.isFinite(m.fps) and m.fps > 0.0) @intFromFloat(@round(m.fps)) else 0;
        const fps_text = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{fps_val}) catch "FPS: 0";
        const text_w: i32 = @intCast(fps_text.len * 6 * 2);
        const fx = @max(bar_x, @as(i32, @intCast(engine.width)) - text_w - 20);
        pixel_mod.drawPixelText(engine, fx, bar_y + 1, 2, fps_text, pixel_mod.packColor(180, 255, 195, 255));
    }
}

pub fn render_system(it: *ecs.iter_t) void {
    const world = it.world;
    const engine = Engine.getEngine(world);
    const phys = C.singletonGetSafe(world, C.PhysicsState) orelse return;
    const arena = engine.arena.allocator();

    // 1. MaterialGrid terrain, sand, and liquids (sky_buffer shows behind .air)
    if (C.singletonGetSafe(world, mw.MaterialGrid)) |grid| {
        grid.renderToBuffers(engine.pixel_buffer, engine.effect_buffer, engine.width, engine.height);
    }

    // 2. Collect AttachedTo links for jelly blobs & player tail
    const attachments_group = if (C.singletonGetSafe(world, C.PlayerAttachmentsGroup)) |g| g.entity else 0;
    const player_entity = if (C.singletonGetSafe(world, C.PlayerContainer)) |pc| pc.entity else 0;
    const player_reservoir = if (player_entity != 0 and ecs.id(C.LiquidReservoir) != 0)
        ecs.get(world, player_entity, C.LiquidReservoir)
    else
        null;

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

    // 2b. Core-to-core connecting arms & outer membrane capsules
    const tether_color = pixel_mod.packColor(190, 50, 80, 255);
    for (links.items) |link| {
        if (link.is_tail) continue;
        if (link.child_is_landable and link.parent_is_landable) {
            pixel_mod.drawCapsuleFilled(
                engine,
                link.parent_pos.x,
                link.parent_pos.y,
                5.5,
                link.child_pos.x,
                link.child_pos.y,
                5.5,
                tether_color,
                Effect.none,
            );
        } else if (!link.child_is_landable and !link.parent_is_landable) {
            const cap_r0: f32 = if (link.landable_center_pos != null) 4.5 else @max(1.4, link.parent_r * 0.55);
            const cap_r1: f32 = if (link.landable_center_pos != null) 4.5 else @max(1.4, link.child_r * 0.55);
            pixel_mod.drawCapsuleFilled(
                engine,
                link.parent_pos.x,
                link.parent_pos.y,
                cap_r0,
                link.child_pos.x,
                link.child_pos.y,
                cap_r1,
                link.color,
                link.effect,
            );
        }
    }

    // 2c. Jelly PlayerLandable cores, articulated non-jelly joints/heads, and unlinked Verlet nodes
    var v_it = ecs.query_iter(world, phys.verlet_query);
    while (ecs.query_next(&v_it)) {
        const positions = ecs.field(&v_it, C.Position, 0).?;
        const colliders = ecs.field(&v_it, C.Collider, 2) orelse continue;
        const ents = v_it.entities();

        for (positions, colliders, 0..) |pos, col, i| {
            const e = ents[i];
            const has_links = ecs.get_target(world, e, ecs.id(C.AttachedTo), 0) != 0;
            const is_landable = ecs.has_id(world, e, ecs.id(C.PlayerLandable));
            const is_tail = attachments_group != 0 and ecs.has_pair(world, e, ecs.ChildOf, attachments_group);
            const is_jelly_skin = has_links and !is_landable and findLandableCenterPos(world, e) != null;
            if (is_tail or is_jelly_skin) continue;

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

    // 4. Non-Verlet actors (Player with visible stomach meter, Gun, Bullets)
    if (phys.render_actor_query) |actor_q| {
        var aq_it = ecs.query_iter(world, actor_q);
        while (ecs.query_next(&aq_it)) {
            const positions = ecs.field(&aq_it, C.Position, 0).?;
            const colliders = ecs.field(&aq_it, C.Collider, 1).?;
            const renderables = ecs.field(&aq_it, C.Renderable, 2).?;
            const ents = aq_it.entities();

            for (positions, colliders, renderables, 0..) |pos, col, rend, i| {
                const e = ents[i];
                if (e == player_entity) {
                    const p_r = switch (col) {
                        .circle => |c| c.r,
                        .box => |b| @max(b.max.x - b.min.x, b.max.y - b.min.y) * 0.5,
                    };
                    drawPlayerBodyWithReservoir(engine, pos, p_r, player_reservoir);
                    continue;
                }

                const is_gun = ecs.id(C.Gun) != 0 and ecs.has_id(world, e, ecs.id(C.Gun));
                const color = if (is_gun) blk: {
                    const has_ammo = if (player_reservoir) |pr| pr.hasAmmo() else true;
                    break :blk if (has_ammo)
                        pixel_mod.packColor(205, 70, 255, 255)
                    else
                        pixel_mod.packColor(145, 145, 160, 255);
                } else pixel_mod.packColor(rend.color.r, rend.color.g, rend.color.b, rend.color.a);

                const effect = ecs.get(world, e, Effect) orelse &Effect.none;
                drawEntityShape(engine, pos, col, color, effect.*);
            }
        }
    }

    // 5. HUD overlay (Reservoir gauge + room objective)
    drawHUD(world, engine);
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
