# Session 1 Plan: Cleanup, Bug Fixes & Module Split

## Goal
Leave all existing behavior intact (except fixing actual bugs), prune dead code, split the two oversized files (`src/game/systems.zig` and `src/main.zig`), and lock in correctness with unit tests—**no new gameplay features**.

## Pre-Session Checklist
- Confirm `zig 0.17.1 build run` launches cleanly on branch `lib_updates` and commit the Zig `0.17.1` / SDL3 / `zflecs` upgrade first.
- Keep `zig 0.17.1 build test` and `zig 0.17.1 build -Doptimize=ReleaseFast` passing at every step.

---

## 1. Fix Concrete Gameplay & Simulation Bugs (`src/game/`)

### Weapons & Aiming
- **`shoot_system` cooldown freeze (`src/game/systems.zig`):** Decrement `gun.cooldown` before returning early on `!input.is_pressing` so releasing the trigger doesn't freeze cooldown mid-cycle.
- **System order (`src/main.zig`):** Register `gun_aim` *before* `shoot` so bullets spawn from the current frame's aimed gun position rather than 1 frame behind.

### Collision & Queries
- **`playerTouchesLandable` (`src/game/systems.zig`):**
  - Add `defer ecs.iter_fini(&q_it);` so early `return true` does not leak the Flecs iterator.
  - Require a top-facing contact (`contact.n.y > 0.5`) so touching a jelly core from the side/underneath doesn't grant grounded movement/jumping.
- **`physics_collision_system` (`src/game/systems.zig`):**
  - Replace `g_colliders[i].box` with `getWorldAABB(gp, g_colliders[i])` so `.circle` `Ground` entities don't panic on union field access.
  - Deduplicate `doomed_bullets` (just like `doomed_ground`), ignore already-doomed bullets in subsequent tile/bullet checks, and run `ecs.delete` *after* the bullet-vs-bullet loop.
  - Replace fixed `[64]` deletion arrays with `engine.arena.allocator()` lists (now safe since `Engine.arena` uses `init.gpa`).
- **`bullet_cleanup_system` (`src/game/systems.zig`):** Add `pos.y < 0` to out-of-bounds deletion (`pos.x < 0 or pos.x > w or pos.y < 0 or pos.y > h`).
- **`verlet_bullet_collision_system` (`src/game/systems.zig`):** Negate `m.n` on the `.box` bullet branch (`circleToAABBManifold(world_v_circle, world_b_aabb, &m)` produces `Verlet -> Bullet`, opposite to `.circle`'s `Bullet -> Verlet`).
- **`player_controller_system` & `player_clamp_system` (`src/game/systems.zig`):** Account for collider radius when clamping to screen bounds, and resolve wall/floor collisions cleanly so moving fast near a wall doesn't leave a rollback gap.

### Reset & Lifecycle
- **Ownership groups (see `docs/WORLD_RESET_AND_ENTITY_LIFECYCLE.md`):**
  - Add `CreaturesGroup` (for `spawn_jelly_blob`) and `PlayerAttachmentsGroup` (for `spawn_player_tail`) so `reset_game` deletes and respawns jellies and tail segments cleanly instead of leaking duplicates.
  - Reset `Gun.cooldown`, `RecoilImpulse`, and any active `ExplosionParticle` entities on reset.
  - Update `MouseCursor` position *before* `ecs.progress` (or read `AimTarget` directly) so `reach_system` isn't 1 frame stale.

---

## 2. Fix Shader & Pixel Buffer Bugs (`src/engine/`)

- **`src/engine/shaders.zig`:**
  - Fix `hasFlag` float precision by rounding (`floor(efx.r * 255.0 + 0.5)`) or switching `effect_texture` to `GL_RG8UI` + `usampler2D`.
  - Fix `BIT_DISTORT`, `BIT_HEAT`, and `BIT_CHROMATIC` overwriting prior `result` (`BLOOM`/`GLOW`/`BLUR`) by sampling/compositing consistently instead of clobbering `result` with raw `u_color`.
  - Fix `BIT_DISSOLVE` by using `discard;` instead of `result.a = 0.0` (which has no effect with blending disabled).
- **`src/game/systems.zig` (`explosion_system`):** Move explosion rendering to `ecs.OnStore` (after background restore, alongside `render_system`) and remove the dead `setAlpha` opacity math until alpha blending is actually implemented in `pixels.zig`.

---

## 3. Split Monoliths & Prune Dead Code

### Engine Cleanup
- Move `drawLinePixels` and `drawCirclePixels` from `src/game/systems.zig` into `src/engine/pixels.zig` (with unit tests for clipping).
- Remove duplicate `pixels.restoreBackground(self: *Engine)`.
- Fix `src/utils/benchmark.zig` to compile on Zig `0.17.1` (`std.Io.Timestamp` + matching `NamedFn` signature) or delete it if unused.

### Split `src/game/systems.zig` into `src/game/systems/`
- `src/game/systems/player.zig` — `player_controller_system`, `player_clamp_system`, `playerTouchesLandable`, `resolvePlayerLandableContacts`
- `src/game/systems/weapons.zig` — `gun_aim_system`, `shoot_system`, `bullet_cleanup_system`, `right_controller_stick_set_mouse_xy_system`
- `src/game/systems/physics.zig` — `gravity_system`, `physics_movement_system`, `physics_collision_system`, `explosion_system`, `getWorldAABB`, `checkCollision`, `resolveBody`
- `src/game/systems/verlet.zig` — `verlet_integration_system`, `attachment_solver_system`, `reach_system`, `verlet_collision_system`, `verlet_self_collision_system`, `verlet_bullet_collision_system`, `resolveVerletBody`
- `src/game/systems/render.zig` — `render_system`, `effect_zone_system`, `draw_attached_constraints_system`, cached debug collider query (`debug_draw_colliders`)
- Re-export through `src/game/systems.zig` so `main.zig` wiring stays clean.

### Extract World Setup from `src/main.zig`
- Move `spawn_initial_entities`, `spawn_level`, `spawnGroundGrid`, `spawn_player_tail`, `spawn_jelly_blob`, and `reset_game` into `src/game/world.zig`.

### Prune Unused Symbols
- Remove empty `seek_system` registration & function.
- Remove unused constants/fields/helpers: `JUMP_IMPULSE`, `JELLY_FRICTION`, `JELLY_RESTITUTION`, `VerletState.mass`, `OffsetDimensions`, `offsetDimensionsToAABB`, `usize_to_f32`, commented-out old constraint types/systems (`DistanceConstraint`, `TendencyTowards`, `ConstraintData`), and stray `docs/physics_world.zig`.

---

## Verification / Done Criteria
- `zig 0.17.1 build` and `zig 0.17.1 build -Doptimize=ReleaseFast` pass cleanly.
- `zig 0.17.1 build test` passes, with new unit tests covering:
  - `pixels.drawRect` out-of-bounds clipping & `drawLinePixels` bounds safety
  - `zoot_c2` normal direction invariants (`circleToCircleManifold`, `circleToAABBManifold`)
  - `world.reset_game` leaving zero leaked bullets/jellies/tail entities
- Manual run (`zig 0.17.1 build run`): pressing `R` cleanly resets player, tail, jellies, and ground without duplicates; shooting single clicks feels crisp with zero frozen cooldown; debug overlay (`\``) works without per-frame query leaks.
