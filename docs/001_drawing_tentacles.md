You're in great shape actually — you have verlet nodes, constraints, and a pixel buffer. The tentacle rendering fits naturally into your existing `render_system` style. Here's exactly how to do it:

## The Plan

You already have:
- `Position` — your node positions (verlet chain)
- `pixel_buffer` — you can write to it directly
- `drawLinePixels` / `drawCirclePixels` — already in your systems file

So you don't even need a shader yet. You can do **CPU-side SDF capsule rendering** into your pixel buffer, which fits your architecture perfectly.

---

## Step 1: Add a Tentacle tag component

In your `components.zig`:

```zig
pub const TentacleNode = struct {
    radius: f32 = 8.0,  // fat at base, thin at tip
    index: u32 = 0,     // position in chain (0 = root)
    chain_id: u32 = 0,  // which tentacle this belongs to
};
```

---

## Step 2: A capsule fill function

Add this to your `systems.zig` — this fills a capsule between two points into your pixel buffer:

```zig
fn drawCapsuleFilled(engine: *Engine, ax: f32, ay: f32, bx: f32, by: f32, r: f32, color_body: u32, color_shadow: u32) void {
    const PIXEL_SIZE: f32 = 4.0; // pixel grid snap — tune this

    // Bounding box of the capsule
    const min_x = @as(i32, @intFromFloat(@floor((@min(ax, bx) - r) / PIXEL_SIZE) * PIXEL_SIZE));
    const min_y = @as(i32, @intFromFloat(@floor((@min(ay, by) - r) / PIXEL_SIZE) * PIXEL_SIZE));
    const max_x = @as(i32, @intFromFloat(@ceil((@max(ax, bx) + r) / PIXEL_SIZE) * PIXEL_SIZE));
    const max_y = @as(i32, @intFromFloat(@ceil((@max(ay, by) + r) / PIXEL_SIZE) * PIXEL_SIZE));

    var py = min_y;
    while (py <= max_y) : (py += @as(i32, @intFromFloat(PIXEL_SIZE))) {
        var px = min_x;
        while (px <= max_x) : (px += @as(i32, @intFromFloat(PIXEL_SIZE))) {
            // Snap to pixel grid center
            const sx = @as(f32, @floatFromInt(px)) + PIXEL_SIZE * 0.5;
            const sy = @as(f32, @floatFromInt(py)) + PIXEL_SIZE * 0.5;

            // Capsule SDF
            const d = sdCapsule(sx, sy, ax, ay, bx, by, r);

            if (d < 0.0) {
                // Two-tone shading: top-left = light, bottom-right = dark
                // Use distance from capsule center axis for the split
                const shade_bias = (sx - ax) - (sy - ay); // diagonal light dir
                const c = if (shade_bias > 0) color_body else color_shadow;

                // Fill a PIXEL_SIZE x PIXEL_SIZE block
                var fy: i32 = 0;
                while (fy < @as(i32, @intFromFloat(PIXEL_SIZE))) : (fy += 1) {
                    var fx: i32 = 0;
                    while (fx < @as(i32, @intFromFloat(PIXEL_SIZE))) : (fx += 1) {
                        const ix = px + fx;
                        const iy = py + fy;
                        if (ix >= 0 and iy >= 0 and
                            @as(usize, @intCast(ix)) < engine.width and
                            @as(usize, @intCast(iy)) < engine.height)
                        {
                            const idx = @as(usize, @intCast(iy)) * engine.width + @as(usize, @intCast(ix));
                            engine.pixel_buffer[idx] = c;
                        }
                    }
                }
            }
        }
    }
}

fn sdCapsule(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, r: f32) f32 {
    const abx = bx - ax;
    const aby = by - ay;
    const apx = px - ax;
    const apy = py - ay;
    const ab_dot_ab = abx * abx + aby * aby;
    const t = std.math.clamp(
        if (ab_dot_ab > 0.0) (apx * abx + apy * aby) / ab_dot_ab else 0.0,
        0.0, 1.0
    );
    const cx = ax + t * abx;
    const cy = ay + t * aby;
    const dx = px - cx;
    const dy = py - cy;
    return @sqrt(dx * dx + dy * dy) - r;
}
```

---

## Step 3: Tentacle render system

Add this system — it queries nodes in a chain and draws capsules between consecutive pairs:

```zig
pub fn tentacle_render_system(it: *ecs.iter_t, positions: []Position, nodes: []components.TentacleNode) void {
    const engine = Engine.getEngine(it.world);
    const world = it.world;

    const color_body: u32 = 0xFF7B2D6B;    // light purple
    const color_shadow: u32 = 0xFF3D1040;  // dark maroon
    const color_shadow_blob: u32 = 0x883D1040; // semi-transparent for drop shadow

    // Draw drop shadow pass first (offset down-right by a few pixels)
    for (0..it.count()) |i| {
        const node = nodes[i];
        if (node.index == 0) continue; // skip root, we draw segment FROM parent

        // Find the previous node in this chain
        // (In your setup, the parent entity has index-1 and same chain_id)
        // Simple approach: query for it
        const prev_pos = getPrevNodePos(world, node.chain_id, node.index - 1) orelse continue;
        const pos = positions[i];

        const shadow_offset: f32 = 5.0;
        const r = node.radius;
        drawCapsuleFilled(engine,
            prev_pos.x + shadow_offset, prev_pos.y + shadow_offset,
            pos.x + shadow_offset, pos.y + shadow_offset,
            r, color_shadow_blob, color_shadow_blob
        );
    }

    // Draw body pass
    for (0..it.count()) |i| {
        const node = nodes[i];
        if (node.index == 0) continue;

        const prev_pos = getPrevNodePos(world, node.chain_id, node.index - 1) orelse continue;
        const pos = positions[i];
        const r = node.radius;

        drawCapsuleFilled(engine, prev_pos.x, prev_pos.y, pos.x, pos.y, r, color_body, color_shadow);
    }
}

fn getPrevNodePos(world: *ecs.world_t, chain_id: u32, index: u32) ?Position {
    var desc = ecs.query_desc_t{};
    desc.terms[0] = .{ .id = ecs.id(components.TentacleNode) };
    desc.terms[1] = .{ .id = ecs.id(Position), .inout = .In };
    const q = ecs.query_init(world, &desc) catch return null;
    defer ecs.query_fini(q);
    var q_it = ecs.query_iter(world, q);
    while (ecs.query_next(&q_it)) {
        const ns = ecs.field(&q_it, components.TentacleNode, 0).?;
        const ps = ecs.field(&q_it, Position, 1).?;
        for (0..q_it.count()) |i| {
            if (ns[i].chain_id == chain_id and ns[i].index == index) {
                ecs.iter_fini(&q_it);
                return ps[i];
            }
        }
    }
    return null;
}
```

---

## Step 4: Taper the radius

When you spawn the chain, set radius to taper:

```zig
const total_nodes = 10;
for (0..total_nodes) |i| {
    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(total_nodes - 1));
    const radius = std.math.lerp(14.0, 3.0, t); // fat root → thin tip
    _ = ecs.set(world, node_entity, TentacleNode, .{
        .radius = radius,
        .index = @intCast(i),
        .chain_id = 0,
    });
}
```

---

## What this gives you

- ✅ Pixel-grid snapping (the chunky retro look)
- ✅ Two-tone flat shading (light/dark split)
- ✅ Drop shadow pass
- ✅ Tapering radius
- ✅ Plugs into your existing verlet/IK — nodes move, rendering just reads positions

The `getPrevNodePos` query is a bit inefficient (queries every frame per node) — once it's working you can replace it by storing node positions in a fixed array per chain instead.
