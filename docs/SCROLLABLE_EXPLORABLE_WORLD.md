# Scrollable And Explorable World

## Purpose

This document outlines the transition from the current static screen-sized box to a map that can be explored with a scrolling camera.

The intended result is a world with coordinates independent of the viewport:

```text
world position -> camera transform -> screen/logical pixel position
```

The world can be larger than one screen, streamed in chunks, and eventually contain destructible material terrain, creatures, checkpoints, and points of interest.

## Current Static-Arena Assumptions

The current project treats logical screen dimensions as level dimensions:

- the player starts near `engine.width / 2`, `engine.height / 2`
- left/right walls use screen width
- the floor is placed at `engine.height - 50`
- rendering draws entity `Position` directly into `pixel_buffer`
- mouse input is converted from window coordinates to logical buffer coordinates, not world coordinates
- player clamp constrains the player to the logical screen

This works for a contained test arena. A scrollable world must remove the assumption that screen coordinates and world coordinates are the same thing.

## Coordinate Spaces

Keep three coordinate spaces distinct.

| Space | Meaning | Example |
| --- | --- | --- |
| Window space | OS window pixels | SDL mouse event at `(1800, 900)` |
| Logical screen space | Internal render buffer pixels | `(900, 450)` in a 1280x720 buffer |
| World space | Persistent game simulation coordinates | player at `(12500, 640)` |

The central transform is:

$$
screen = world - camera\_top\_left
$$

Or, if camera position represents its center:

$$
screen = world - camera\_center + viewport\_size / 2
$$

All physics, AI, terrain, creature constraints, and spawning use world space. Only rendering, screen culling, and pointer conversion use camera transforms.

## Camera Component

Start with one explicit camera singleton.

```zig
pub const Camera = struct {
    x: f32,
    y: f32,
    viewport_width: f32,
    viewport_height: f32,
};
```

Initially `x` and `y` can mean the camera top-left. This makes render conversion direct:

```zig
const screen_x = world_position.x - camera.x;
const screen_y = world_position.y - camera.y;
```

Later, use a camera center and smoothing if desired. Do not introduce zoom, screen shake, dead zones, look-ahead, and split screen at once.

## Camera Follow System

A camera follow system reads one target position and updates the camera.

```zig
camera.x = target.x - camera.viewport_width * 0.5;
camera.y = target.y - camera.viewport_height * 0.5;
```

Clamp the camera to map bounds:

```zig
camera.x = std.math.clamp(camera.x, 0.0, map_width - camera.viewport_width);
camera.y = std.math.clamp(camera.y, 0.0, map_height - camera.viewport_height);
```

Use camera follow only after the renderer correctly accepts world coordinates. Otherwise player movement and camera movement will be mixed together and debugging becomes difficult.

## Rendering Migration

Current rendering passes ECS positions directly into CPU pixel drawing. Convert every world entity draw call to camera-relative coordinates.

```zig
const camera = ecs.singleton_get(world, C.Camera).?;
const screen_x = position.x - camera.x;
const screen_y = position.y - camera.y;

pixels.drawRect(engine, screen_x, screen_y, width, height, color, effect);
```

Before expensive drawing, cull using the entity's world AABB against the camera's visible world rectangle:

```text
visible world rectangle:
  [camera.x, camera.x + viewport_width]
  [camera.y, camera.y + viewport_height]
```

Do not change entities to screen-relative positions. That would make physics fail as the camera moves.

## Pointer And Aim Conversion

The mouse first converts from window space to logical screen space. Add the camera origin to get world space:

```zig
const logical = engine.windowToLogical(input.mouse_x, input.mouse_y);
const camera = ecs.singleton_get(world, C.Camera).?;

const world_aim = C.PlayerAim{
    .x = @as(f32, @floatFromInt(logical.x)) + camera.x,
    .y = @as(f32, @floatFromInt(logical.y)) + camera.y,
};
```

For a controller, derive the aim direction in world space from the player's world position. The current screen-edge ray technique should be replaced when maps can scroll, because screen edges have no stable meaning in world space.

## Map Bounds And Player Clamp

Replace screen-based `player_clamp_system` with map bounds or terrain collision.

```zig
pub const MapBounds = struct {
    width: f32,
    height: f32,
};
```

Early map behavior can clamp players to `MapBounds`. The long-term behavior should rely primarily on terrain and reserve map bounds for world limits, void areas, or streaming boundaries.

Never clamp player positions to `engine.width` or `engine.height` once screen and world space are separated.

## Map Representation

The project should not create one ECS entity for every cell in a large explorable world. Use chunks.

```text
Map
  chunk (0, 0)
  chunk (1, 0)
  chunk (2, 0)
  ...
```

Each chunk has fixed world dimensions and can own:

- terrain/material cells
- a rendered pixel region or GPU texture region
- collision data for stable terrain
- active simulation flags for sand/water/etc.
- procedural generation seed or saved modifications
- spawn markers or placed gameplay objects

The material-world plan in [HYBRID_ENGINE_ARCHITECTURE.md](HYBRID_ENGINE_ARCHITECTURE.md) describes cell and chunk behavior. This document defines how chunks appear around a moving camera/player.

## Active Map Region

Do not simulate, draw, or spawn every map chunk.

Maintain an active rectangle around the camera or all active players:

```text
loaded chunks:  visible chunks + one or two chunk margins
simulated cells: active chunks within the loaded region
rendered chunks: visible chunks only
```

When the camera moves:

1. Determine the visible chunk coordinate range.
2. Load/generate missing chunks plus a margin.
3. Activate chunks that need material updates.
4. Unload distant chunks after their modifications are saved.

For a first scrollable prototype, use a finite preloaded map and only cull rendering. Add asynchronous loading and procedural generation later.

## Terrain And Collision

For a world larger than the viewport, terrain queries must be local.

### Initial Option: Chunk Collider Lists

Each chunk owns a list of static terrain rectangles. Query only the chunks overlapped by a player's or Verlet particle's local AABB.

This preserves current Cute C2 contacts while avoiding a scan over the full map.

### Long-Term Option: Material Grid Queries

Use chunked material cells for terrain occupancy. Player/bullet/Verlet queries inspect nearby cells or extracted static rock rectangles.

This is the recommended direction because it supports destruction and cellular materials. See [HYBRID_ENGINE_ARCHITECTURE.md](HYBRID_ENGINE_ARCHITECTURE.md) for the stable-rock/mobile-material hybrid approach.

## Object Spawning And Persistence

Level entities should not be spawned only once at application startup. They belong to map chunks or level definitions.

Each placed object needs a policy:

| Object | Spawn policy | Persistence policy |
| --- | --- | --- |
| Static decoration | Load with chunk | no simulation state needed |
| Enemy creature | Spawn when chunk activates | save death/state if needed |
| Pickup | Spawn when chunk activates | save collected state |
| Bullet/effect | Spawn at runtime | remove when expired or far away |
| Material modification | Exists in chunk cell data | save changed cells |

The `CreatureGroup` lifecycle plan remains useful, but a large map eventually uses per-chunk ownership roots rather than one global creature group:

```text
MapChunkRoot
  terrain collider entities
  creature roots
  placed props
```

When a chunk unloads, delete its runtime entities after serializing any state that must persist.

## Reset, Death, And Checkpoints

World reset has multiple meanings in an explorable map. Keep them separate.

| Event | Intended scope |
| --- | --- |
| Player death | restore player at checkpoint; preserve world unless design says otherwise |
| Restart level | restore level/chunk state from its initial data |
| Reload save | load persistent map modifications and player state |
| Development reset key | reset currently loaded map/chunks to their authoring state |

The current full reset key behaves like "restart level." Do not use it as the final player-death behavior unless the game is intentionally arcade-like.

## Recommended Migration Steps

### Step 1: Introduce World-Space Camera

1. Add `Camera` singleton with a viewport equal to the engine logical size.
2. Keep the current map dimensions equal to the screen dimensions.
3. Convert rendering positions to `world - camera`.
4. Convert mouse logical position to `logical + camera`.

Checkpoint: game looks and behaves exactly as before when camera is `(0, 0)`.

### Step 2: Build A Larger Fixed Map

1. Define `MapBounds` larger than the viewport.
2. Create terrain at world coordinates beyond the first screen.
3. Replace screen clamp with map bounds.
4. Add camera follow for the primary player.

Checkpoint: walking right scrolls the map; collision and aiming remain aligned with visible pixels.

### Step 3: Camera Culling

1. Add world-AABB visibility tests to actor/terrain rendering.
2. Draw only objects overlapping the visible camera rectangle.
3. Keep simulation broad for now if the map is still small.

Checkpoint: moving through a large finite map does not draw offscreen objects.

### Step 4: Chunked Map Data

1. Divide map terrain into chunks.
2. Store each chunk's coordinate, content, collision data, and dirty state.
3. Query nearby chunk collision rather than all terrain.
4. Associate static entities and creatures with chunk ownership roots.

Checkpoint: collision work depends on nearby chunks rather than the entire map size.

### Step 5: Streaming And Persistence

1. Load/generate chunks around the active camera/player area.
2. Save changed material cells and persistent object state before unload.
3. Unload distant chunks and their runtime entities.
4. Add checkpoint/save data separately from debug reset.

Checkpoint: the player can travel farther than loaded memory without losing intended world changes.

## Common Failure Modes

### Moving The World Instead Of The Camera

Do not subtract camera movement from every entity position each frame. Positions are world truth. Only the renderer transforms them.

### Mixing Mouse Spaces

If aim appears offset while scrolling, a world/screen conversion was skipped or applied twice. Keep the conversion boundary in one place.

### Screen-Sized Physics Assumptions

Floor placement, walls, player clamp, controller aim rays, and reset spawn points must use map/world coordinates, not engine dimensions.

### Loading Everything

An apparently finite map can become expensive if every terrain tile, creature, and material cell remains active. Chunk ownership and active regions solve this gradually.

### Camera And Physics Coupling

Camera smoothing must not alter physics timestep or entity positions. A camera can lag aesthetically; collisions cannot.

## Success Criteria

- Entity positions remain in stable world space while the viewport moves.
- Mouse/controller aiming hits the same world location shown on screen.
- Terrain and player collision work outside the initial screen-sized region.
- Rendering culls offscreen entities.
- Reset semantics distinguish whole-level restart from player respawn.
- Chunking can be introduced without changing player, projectile, or Verlet core simulation models.