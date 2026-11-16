# Session 2 Plan: Simulation Stability & Visual Readability

## Goal
Make physics frame-rate-independent and stable under strong collisions, and upgrade CPU rendering primitives so actors, jellies, and tails look like real game entities instead of debug AABBs and constraint lines.

*(Prerequisite: Session 1 complete.)*

---

## 1. Fixed-Timestep Simulation Loop (`src/main.zig`)

- Replace variable `dt` passed directly to `ecs.progress(world, dt)` with a fixed-step accumulator:
  - `fixed_dt: f32 = 1.0 / 120.0`
  - `max_steps_per_frame: usize = 8` (drop excess accumulated time if a stall occurs)
- Poll input once per render frame, step simulation `0..N` times at `fixed_dt`, then render once.
- **Why first:** Right now Verlet damping (`friction`), gravity, and 24x solver iterations depend directly on monitor refresh rate (60 Hz vs 120 Hz). Nothing should be tuned until `fixed_dt` is in place.

---

## 2. Deterministic Verlet / PBD Solver (`src/game/systems/verlet.zig`)

See `docs/HYBRID_ENGINE_ARCHITECTURE.md` Part II for background. Concrete changes:

- **Remove `Velocity` from Verlet entities** (`spawn_player_tail`, `spawn_jelly_blob`, and `verlet_integration` filter) so `Position - old_pos` is the sole velocity authority.
- **Unify the PBD relaxation loop** instead of running 24 attachment iterations per Flecs target batch *before* terrain/self collisions:
  1. Predict all Verlet positions (`verlet_predict`).
  2. Run `solver_iterations` (start at `6`–`8`, not `24`) of:
     - attachment distance constraints (`AttachedTo`) across all pairs in deterministic order
     - terrain contact projection
     - player-landable core projection
     - Verlet self-collision (excluding directly linked pairs and optional same-creature core/perimeter rules; see `docs/ARBITRARY_VERLET_CREATURES.md`)
  3. Finalize/clamp implicit velocity if needed.
- **Name Verlet position-adjustment policies explicitly:**
  - `translatePreserveVelocity(pos, state, dx, dy)` — moves both `pos` and `old_pos` (no energy injected)
  - `translateInjectVelocity(pos, dx, dy)` — moves only `pos` (intentional bounce/squish)
  - `applyImpulse(state, ix, iy)` — adjusts `old_pos` (bullet smack)

---

## 3. Better CPU Pixel Primitives & Visuals (`src/engine/pixels.zig`, `render.zig`)

Currently `render_system` draws every entity—including circular player, bullets, and jelly nodes—as solid `drawRect` AABBs, and `draw_attached_constraints_system` draws thin blue debug lines.

- **Add fast filled primitives in `src/engine/pixels.zig`:**
  - `drawCircleFilled(engine, cx, cy, r, color, effect)` using horizontal span `@memset` per scanline (matches `drawRect` speed and clipping).
  - `drawCapsuleFilled(engine, x0, y0, r0, x1, y1, r1, color, effect)` for tapered tentacles/limbs and jelly skin membranes (see `docs/001_drawing_tentacles.md`).
  - Optional alpha-blended `drawRectAlpha` / `drawCircleAlpha` if needed for fading particles (`explosion_system`).
- **Update `render_system`:**
  - Draw `.circle` colliders with `drawCircleFilled` and `.box` colliders with `drawRect`.
  - Render player tail / jelly spokes with capsules or keep constraint lines behind a `debug_mode` toggle instead of always-on blue wireframes.
- **Define `Effect` layering rules:**
  - Actors write color without unconditionally wiping underlying effect zones, or `effect_zone_system` always runs cleanly after actor drawing with explicit blend/override semantics.

---

## 4. Lightweight Profiling & Debug Counters

Before optimizing collision or rendering further, add simple per-frame debug metrics (printed on toggle or title bar / log):
- Fixed steps run per frame
- Entity counts (bullets, ground tiles, Verlet particles)
- Collision checks performed vs. hits
- Frame update ms vs. render/GL upload ms

---

## Verification / Done Criteria
- Jelly physics feel identical whether VSync is 60 Hz or uncapped / simulated at 120 Hz.
- Player landing on and pushing jellies behaves predictably without permanent stretching or popping.
- Player, bullets, jellies, and tail render as crisp circles/capsules; debug wireframes only appear in `debug_mode`.
- `zig 0.17.1 build test` includes unit tests for `drawCircleFilled` / `drawCapsuleFilled` clipping and PBD distance convergence.
