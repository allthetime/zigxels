# Session 3 Plan: Material Grid & First Playable Vertical Slice

## Goal
Replace the O(G × N) `GroundGrid` ECS tiles with a real cellular `MaterialGrid`, and build **one complete, fun single-room vertical slice** testing the core game concept from `TODO.txt` (*"you are what you drink"*).

*(Prerequisites: Sessions 1 and 2 complete.)*

---

## 1. Fixed-Size `MaterialGrid` (No Infinite Streaming Yet)

Instead of jumping straight to infinite world streaming and chunk persistence, start with a single screen-matched grid at **4×4 (or 2×2) display pixel scale**—e.g. `320 × 180` cells for a `1280 × 720` pixel buffer (`57,600` cells total, trivially fits in L2 cache):

- **Create `src/game/material_world.zig`:**
  - `Material = enum(u8) { air, rock, sand, liquid_purple, liquid_water }` (keep it to 4–5 materials first).
  - `Cell` struct: `material`, `color_variant`, `updated_tick` (or simple ping-pong bit).
  - Operations: `getCell`, `setCell`, `carveCircle(cx, cy, radius)`, `spawnSplash(cx, cy, radius, mat)`.
- **Cellular step (`stepMaterials`):**
  - Bottom-to-top scan with alternating left/right horizontal parity per tick to avoid directional bias.
  - `sand`: falls down, then diagonally down-left/down-right; sinks through liquid.
  - `liquid`: falls down, flows sideways with randomized/alternating preference.
- **Rendering:**
  - Render `MaterialGrid` into `engine.background_buffer` / `pixel_buffer` (scaling each cell cleanly to `cell_size × cell_size` pixels) only when dirty or per cell loop (~57k cells is sub-millisecond).
  - Retire `GroundGrid` ECS entities and `pixels.restoreRect`.

---

## 2. Swept Bullet & Local Grid Collision

- **Bullets vs. `MaterialGrid`:** Use grid DDA ray-marching from `old_pos` to `new_pos` so fast bullets never tunnel through thin rock cells. On impact with `rock`, carve a small crater (and optionally turn carved cells into falling `sand`/debris).
- **Player & Verlet vs. `MaterialGrid`:** Query only the grid cells overlapping the entity's world AABB (turns `O(G × N)` terrain checks into `O(1)` local cell lookups per entity). Keep outer screen walls/floor simple or represent them as indestructible boundary rock.

---

## 3. First Playable Loop ("You Are What You Drink")

Test the core loop from `TODO.txt` in one deliberate puzzle room before adding more content or camera scrolling:

1. **Empty / low-ammo start:** Player can move, jump, and trigger a single weak recoil "dry push" on click (with a cooldown) without shooting material.
2. **Drinkable liquid pool:** Touching or holding interact/submerging in `liquid_purple` cells consumes nearby liquid cells and fills a visible player reservoir/stomach meter (drawn directly on screen or on the player body).
3. **Material ammo & recoil:** Shooting spends stored liquid, spawns projectile/liquid blobs with strong recoil boost, carves destructible rock or pushes/damages a jelly creature, and runs out when empty.
4. **Win / Reset loop:** Clear the room objective (reach goal or defeat the jelly using limited liquid) and reset cleanly with `R`.

---

## Explicitly Deferred (Do NOT Build in Session 3)
- Infinite chunk streaming / save-load (`SCROLLABLE_EXPLORABLE_WORLD.md`)
- Lua hot-reloading (`HOT_RELOADABLE_SCRIPTING_SYSTEM.md`)
- Multi-threading job queues (`MULTI_THREADING.md`)
- Renderer backend VTables (`RENDERING.md`)
- Multi-player (`MULTIPLE_PLAYERS_ARCHITECTURE.md`)

Revisit scrolling/camera only *after* this single room proves the core movement + liquid + creature loop is fun.
