# Hybrid Engine Architecture Review And Roadmap

## Purpose

This document describes the current simulation and rendering architecture, identifies the problems that will block a larger game, and proposes a staged direction for a game that combines:

- a responsive platformer-style player controller
- velocity-based projectiles and debris
- Verlet / position-based jelly creatures
- destructible terrain
- Noita-inspired cellular materials such as sand, liquids, gases, heat, and reactions
- pixel-buffer rendering with GPU post-processing

The goal is not to replace every system with one universal physics engine. The useful long-term design is a deliberately hybrid engine in which each simulation model owns the category of behavior it handles well.

## Current Code Map

| Area | Current implementation | Main responsibility |
| --- | --- | --- |
| Player movement | `player_controller_system` in `src/game/systems.zig` | Kinematic platformer movement, jump, recoil, static terrain response |
| Conventional bodies | `gravity_system`, `physics_movement_system`, `physics_collision_system` | Velocity integration, terrain bounce, bullets, explosions |
| Jelly bodies | `verlet_integration_system`, `attachment_solver_system`, `verlet_collision_system`, `verlet_self_collision_system` | Deformable particle motion and distance constraints |
| Player-jelly core contact | `resolvePlayerLandableContacts` | Stable landing on a tagged jelly core while still allowing pushes |
| Terrain | `spawnGroundGrid` in `src/main.zig` | One ECS entity for each 5x5 destructible terrain tile |
| Pixel drawing | `src/engine/pixels.zig` | CPU color and effect buffers |
| Presentation | `src/engine/core.zig`, `src/engine/shaders.zig` | Upload CPU buffers as OpenGL textures and draw a fullscreen quad |

The code is already a hybrid engine. The work ahead is mostly about making its boundaries explicit and scalable.

---

# Part I: How The Current Simulation Works

## Frame Lifecycle

The main loop currently does the following each rendered frame:

1. Measure a variable frame delta with `calculateDeltaTime`.
2. Poll input and write it to an ECS singleton.
3. Restore `background_buffer` into `pixel_buffer` and clear `effect_buffer`.
4. Run `ecs.progress(world, dt)`, executing systems in registration order.
5. Draw cursor and optional debug shapes.
6. Upload the complete color and effect buffers to GPU textures.
7. Run the fullscreen shader and present.

This is easy to reason about and works well while the game is small. It has an important consequence: the physics rate is the render rate, and the number of constraint iterations per second changes with frame rate.

## System Order At Present

The relevant systems are registered in this order:

1. Controller-stick input capture
2. Empty seek system
3. Conventional gravity
4. Shooting
5. Verlet integration
6. Reach-toward behavior
7. Attachment solver
8. Player controller
9. Gun aim
10. Conventional velocity movement
11. Conventional terrain collision
12. Verlet terrain collision and player repulsion for non-landable particles
13. Verlet self collision
14. Bullet-versus-Verlet collision
15. Player screen clamp and cleanup/render systems

This is not invalid, but it mixes simulation phases and gameplay phases. In particular, constraints are solved before terrain/self collision. Those later collision corrections can violate the solved attachment distances until the next frame.

## Conventional Velocity Bodies

Conventional dynamic entities have:

- `Position`
- `Velocity`
- `Collider`
- `PhysicsBody`

They receive gravity from `gravity_system`, move with:

```text
position += velocity * dt
```

and are checked against every `Ground` collider in `physics_collision_system`.

On contact, `resolveBody`:

1. moves the body out of penetration
2. splits its velocity into normal and tangential components
3. reflects the incoming normal component using restitution
4. scales the tangential component with friction

This is a standard, understandable impulse-style response for static terrain. Bullets, particles, and future rigid debris are appropriate users of this path.

## Kinematic Player

The player intentionally does not use the conventional dynamic-body systems. Its controller owns:

- input interpretation
- horizontal acceleration / recoil handling
- gravity and jumping
- X movement followed by static-terrain overlap rollback
- Y movement followed by static-terrain overlap rollback

That makes the player controllable rather than physically neutral. The player is effectively a kinematic body: it decides where it tries to move, then gameplay collision decides what is allowed.

The player also has special interaction with `PlayerLandable` jelly cores. That relationship should remain custom. Making the player a generic rigid body would weaken tight platformer control and complicate recoil, jumping, and aiming.

## Verlet Jelly

A jelly uses multiple entities:

- one large center particle
- perimeter particles
- `AttachedTo` relations for center-to-skin spokes
- `AttachedTo` relations for perimeter links
- `VerletState` storing `old_x`, `old_y`, and damping

Verlet integration derives velocity from position history:

$$
v_t \approx x_t - x_{t-1}
$$

and then predicts a new position:

$$
x_{t+1} = x_t + v_t \cdot d + a\Delta t^2
$$

where $d$ is damping from `VerletState.friction`.

The attachment solver then reduces the error between a child particle and its relation target. This produces a soft-body-like shape without explicit springs or angular constraints.

## Existing Player-Jelly Interaction

The large jelly center has the `PlayerLandable` tag. The player controller probes tagged entities to determine whether it is grounded, then resolves player/core overlap after player movement.

The desired gameplay rule is:

- landing from above: mostly move player outward, cancel downward player velocity, move core slightly
- pushing from side or below: move the core more strongly, preserving the satisfying shove response
- limbs: not landable yet and still react through the existing Verlet systems

The tag is a good ownership boundary. It means "the player controller may treat this entity as a platform/contact surface." It does not mean the object is static or that all systems should treat it as `Ground`.

---

# Part II: Problems And Risks

## 1. Variable Delta Time Changes The Simulation

`calculateDeltaTime` caps the simulation delta at 1/60 seconds. A frame that takes 100 ms runs only 16.67 ms of simulation, so the game visibly slows under a hitch rather than catching up.

More importantly, the jelly gets:

- one integration per rendered frame
- 24 attachment iterations per rendered frame
- one terrain pass per rendered frame
- one self-collision pass per rendered frame

At 120 FPS the jelly receives roughly twice as much solver work per wall-clock second as it does at 60 FPS. Damping is also frame-based rather than time-based.

### Recommended Solution: Fixed Physics Step

Use an accumulator in `main`:

```zig
const fixed_dt: f32 = 1.0 / 120.0;
const max_steps_per_frame: usize = 8;

accumulator += measured_dt;
var step_count: usize = 0;
while (accumulator >= fixed_dt and step_count < max_steps_per_frame) {
    _ = ecs.progress(world, fixed_dt);
    accumulator -= fixed_dt;
    step_count += 1;
}
```

The renderer can still run at the monitor refresh rate. A cap on catch-up steps prevents a long stall from producing a "spiral of death." When the cap is exceeded, drop the excess simulation time deliberately and log/profile it in debug builds.

Use a fixed step before tuning creature stiffness, damping, gravity, or bullet collision. Otherwise every tuning result is tied to the machine's current frame rate.

## 2. Constraint And Contact Solving Are Separated

Current jelly order is approximately:

```text
predict Verlet positions
solve attachments 24 times
resolve terrain contacts
resolve player contacts
resolve jelly self contacts
```

Terrain, player, and self contacts all move positions after attachments were solved. Those moves stretch constraints. The stretch is repaired on the next rendered frame, so the result can look elastic, but the behavior becomes order-dependent and unstable with stronger interactions.

### Recommended Solution: Position-Based Dynamics Iteration

For each fixed simulation step:

```text
1. Predict all Verlet positions.
2. Repeat solver_iterations times:
   a. solve attachment constraints
   b. solve terrain contacts
   c. solve player/core contacts
   d. solve Verlet self contacts
3. Preserve/update old positions according to the desired contact response.
```

This is the central PBD idea: constraints and contacts are all position constraints participating in one iterative relaxation process.

Start with 4 to 8 global iterations, not 24 attachment-only iterations. Measure behavior first. More iterations improve stiffness but cost CPU time.

## 3. The Attachment Solver Is Relation-Batch Dependent

`attachment_solver_system` receives a batch whose `AttachedTo` pair has one resolved target. It performs 24 iterations inside that batch. Since ECS calls the system separately for each target/pair grouping, the final result depends on Flecs table ordering and target grouping.

For a single chain this may be acceptable. For a jelly with a center plus perimeter ring, it means some constraints can be repeatedly solved before others get a chance.

### Options

### Option A: Keep ECS Relations, Add A Global Solver Driver

Build an explicit list of constraints in a `PhysicsState` or `JellyWorld` resource, then iterate that list in the intended order. The ECS components remain authoritative, but the solver controls ordering.

Pros:

- preserves ECS entity relations
- simplest incremental refactor

Cons:

- requires list maintenance when spawning/despawning jellies

### Option B: Use A Jelly Component With Contiguous Particle Storage

Store each jelly's particles and constraints in dedicated arrays. ECS has one `Jelly` entity that references its internal simulation data.

Pros:

- cache-friendly
- deterministic solver order
- easier to implement per-jelly substeps, topology changes, and active sleeping

Cons:

- less granular ECS inspection
- custom data ownership and cleanup

For this project, start with Option A. Move to Option B only if many creatures make ECS relation queries a profiling bottleneck.

## 4. `Velocity` Means Two Different Things

Verlet particles currently receive a `Velocity` component because their query includes it, but Verlet integration ignores it. Their actual velocity is implicit in `Position - old_position`.

This causes conceptual and query confusion:

- conventional systems understand `Velocity` as authoritative motion
- Verlet systems do not
- a new system can accidentally write a Verlet `Velocity` and expect an effect that never happens

### Recommended Direction

Define movement ownership explicitly:

| Movement model | Required state | Velocity owner |
| --- | --- | --- |
| Kinematic player | `Position`, controller state | Player controller |
| Conventional dynamic body | `Position`, `Velocity`, `PhysicsBody` | `Velocity` component |
| Verlet particle | `Position`, `VerletState` | `Position - old_position` |
| Material cell | grid cell state | Cellular update rules |

Remove `Velocity` from Verlet entity creation and from the Verlet integration filter once no other code depends on it. Either remove unused `VerletState.mass`, `JELLY_FRICTION`, and `JELLY_RESTITUTION`, or implement their intended behavior before adding more tunables.

## 5. Verlet Corrections Inject Energy Inconsistently

Moving a Verlet particle's `Position` but not its `old_x` / `old_y` changes its next inferred velocity. This can be useful as an impact impulse, but it must be deliberate.

Current policies vary:

- terrain collision updates old position through `resolveVerletBody`
- player/core landing moves old position with the core correction
- self collision moves only positions, intentionally injecting energy
- bullet impact modifies old position to add an impulse

These are valid tools, but they should be named policies rather than accidental side effects.

### Recommended Helper API

Introduce functions such as:

```zig
fn translateVerletPreserveVelocity(pos: *Position, state: *VerletState, delta: Vec2) void;
fn translateVerletInjectVelocity(pos: *Position, delta: Vec2) void;
fn applyVerletImpulse(state: *VerletState, impulse: Vec2) void;
```

Then contact code states the gameplay intent visibly. For self collision, use a reduced injected impulse or update both positions and old positions with a chosen ratio. This gives squish without uncontrolled energy accumulation.

## 6. The Player Landable Probe Needs A Direction Test

The player uses `playerTouchesLandable` to decide whether it is grounded. If that function accepts every overlap, touching the core from the side or bottom can grant ground movement and jumping.

For a Y-down world, Cute C2's circle-to-circle normal points from player shape A to jelly core shape B. A landing contact has a normal that points mostly downward:

```zig
const is_top_contact = contact.n.y > 0.5;
```

Use a small downward probe and require `is_top_contact`. Keep the actual landing resolver responsible for cancelling downward velocity.

## 7. Bullets Can Tunnel Through Thin Terrain

A bullet moves roughly 16.7 pixels per 60 Hz step at the current speed of 1000 pixels/second. Terrain cells are 5 pixels wide. Because collision is evaluated after final position movement, the bullet can cross an entire cell without ending overlapped.

### Recommended Solution: Swept Collision

For each bullet movement:

1. calculate the segment from previous position to intended position
2. query cells or colliders crossed by the segment
3. find the first impact
4. place bullet at impact point
5. destroy/bounce once

For material terrain, a grid digital differential analyzer (DDA) is ideal. It visits only the cells crossed by the bullet ray and naturally reports the first occupied cell.

## 8. Current Collision Complexity Will Not Scale

Let:

- $G$ be ground colliders
- $V$ be Verlet particles
- $B$ be bullets
- $D$ be conventional dynamic bodies

The current major costs include:

$$
O(GD) + O(GV) + O(V^2) + O(BV)
$$

The `spawnGroundGrid` approach creates many `Ground` entities. One large jelly is still cheap, but multiple creatures, more terrain, and material particles will quickly make the all-pairs loops dominant.

### Recommended Solution: Spatial Partitioning

Use a uniform spatial hash or fixed grid. Each collider inserts its world AABB into overlapped buckets. A contact query checks only nearby buckets rather than every entity.

For this game, material terrain itself will already be a grid. Reuse that grid for terrain queries rather than creating a separate broadphase for terrain. Use a spatial hash for dynamic objects and Verlet particles.

---

# Part III: Destructible Terrain And Materials

## Why The Current ECS Tile Terrain Must Be Replaced

`spawnGroundGrid` creates one entity per 5x5 square. A tile carries `Position`, `Collider`, `Renderable`, `Ground`, and `Destroyable`. On bullet impact, code queues the entity for deletion and calls `restoreRect` to rewrite the background/pixel buffers.

This proves the gameplay idea, but it is unsuitable for cellular materials:

1. An ECS entity per sand grain or material pixel is far too expensive.
2. Collision scans terrain entities rather than querying a local world representation.
3. Rendering is coupled to tile entities and background restoration instead of persistent world state.
4. A removed tile is only "gone"; there is no way for it to become falling rubble, sand, liquid, smoke, or heat.
5. Destruction has a fixed 64-item queue cap per frame. Larger explosions silently stop processing extra hits.
6. One 5x5 tile is too coarse for interesting material reactions but still too many ECS entities for a large map.

## Design Principle: A Material Grid Is The Authority

The material world should be the authoritative source for:

- whether terrain exists
- what material it is
- its color variation
- temperature or other state
- whether it needs an update
- whether it needs render/collision rebuild work

ECS entities should represent actors and discrete objects, not every material cell.

## Recommended Material Data

Start small. A useful initial design is:

```zig
pub const Material = enum(u8) {
    air,
    rock,
    sand,
    water,
};

pub const Cell = packed struct {
    material: Material,
    color_variant: u4,
    temperature: u8,
    updated_tick: u16,
};
```

Do not add all Noita systems immediately. Fire, gas, acid, electricity, pressure, staining, and reactions multiply the debugging surface. Make `air`, `rock`, `sand`, and `water` correct first.

## Chunking

Store cells in chunks rather than one monolithic world array. Good initial chunk sizes are 32x32 or 64x64 cells.

```zig
pub const Chunk = struct {
    cells: [chunk_size * chunk_size]Cell,
    active: bool,
    dirty_render: bool,
    dirty_collision: bool,
};
```

Chunking provides:

- bounded memory management
- local update work
- local GPU texture uploads
- streaming for larger worlds
- a natural unit for saving/loading

Only active chunks should receive cellular updates. A chunk becomes active when material changes inside it or when a neighboring active chunk could move material across its border.

## Initial Material Rules

### Rock

- static solid terrain
- blocks player, bullets, and jelly
- can be removed by damage/explosion
- can optionally become loose sand/debris when broken

### Sand

- moves downward into air
- otherwise moves diagonally down-left or down-right
- swaps with lighter material such as water if desired
- does not need rigid-body collision per grain

### Water

- moves downward first
- flows sideways when blocked
- should use a randomized or alternating side preference to avoid directional bias

### Update Ordering

Update sand bottom-to-top so a grain only moves once per simulation step. Alternate left-to-right and right-to-left iteration every tick, or derive direction from a chunk/tick hash. This prevents a permanent rightward bias.

Use `updated_tick` or two buffers to prevent a moved cell from updating again immediately in its new location.

## Material-Terrain Collision

There are three viable approaches.

### Option A: Direct Grid Sampling

Player, bullet, and Verlet particles query the material cells under their AABB or along a swept path.

Best for:

- bullets
- particle contacts
- sand and water interactions
- immediate implementation

Tradeoff:

- player collision needs careful swept movement and surface normal approximation

### Option B: Rectangles Extracted Per Dirty Chunk

Merge contiguous rock cells into larger static AABBs. Rebuild only dirty chunks. Create one collider per merged rectangle, not one collider per source cell.

Best for:

- stable platformer terrain
- existing Cute C2 collision code
- a terrain material that changes occasionally rather than continuously

Tradeoff:

- extraction code and chunk-border handling
- not a good representation for freely moving sand

### Option C: Hybrid

Use extracted rectangles for stable `rock` and direct grid sampling for mobile materials.

This is the recommended long-term approach. It supports stable player movement while allowing cheap cellular sand/water updates.

## Bullet Destruction In A Material World

Replace tile entity deletion with a material edit operation:

```zig
material_world.carveCircle(hit_position, radius, .rock);
```

The operation should:

1. modify cells in the impact radius
2. mark affected chunks active and render-dirty
3. mark terrain collision dirty if stable rock was removed
4. optionally spawn loose sand/debris or effects

Do not call `restoreRect`. Rendering should derive from current material cells, so an emptied cell renders as air/sky on the next composition step.

## Performance Expectations

A $1280 \times 720$ pixel-resolution material simulation is not an appropriate first CPU target. Simulate at a lower material resolution, such as $320 \times 180$ or $640 \times 360$, then scale pixels visually. Use a material cell size of 2 to 4 display pixels if the game needs a 1280x720 logical render buffer.

The right question is not "how many material pixels exist?" It is "how many cells are active this fixed step?" Active chunks, low simulation resolution, and localized edits are the primary performance tools.

---

# Part IV: Rendering Architecture

## Current Rendering Pipeline

`Engine` owns four CPU buffers:

| Buffer | Current role |
| --- | --- |
| `sky_buffer` | Initial gradient / sky source |
| `background_buffer` | Persistent background and terrain-like base |
| `pixel_buffer` | Frame color buffer sent to GPU |
| `effect_buffer` | Per-pixel flags and intensity sent to GPU |

Each rendered frame copies `background_buffer` to `pixel_buffer`, clears `effect_buffer`, draws ECS rectangles into `pixel_buffer`, uploads both full buffers to OpenGL, and draws a fullscreen quad.

This is a good bootstrap renderer. It gives pixel-level control on CPU with straightforward GPU effects.

## Current Strengths

- fixed logical resolution with nearest-neighbor texture filtering
- clear CPU-to-GPU boundary
- effects stored separately from color data
- fullscreen shader allows heat, distortion, glow, and chromatic effects without modifying gameplay rendering code
- `drawRect` uses clipped row writes and `@memset`, which is appropriate for dense CPU rectangle drawing

## Rendering Problems

### Background Is Doing Too Much

`background_buffer` currently stands in for both visual background and destroyed terrain persistence. A material world cannot be maintained safely by copying sky pixels back into a rectangle when a terrain tile is deleted.

### Every Frame Uploads Entire Textures

At 1280x720:

- color buffer upload: roughly 3.5 MiB
- effect buffer upload: roughly 1.8 MiB

This is acceptable now. It becomes worth optimizing only after profiling shows texture upload stalls or after the game moves to a larger logical resolution.

### Effects Do Not Have A Clear Layering Contract

`drawRect` writes both color and effect flags. A later rectangle can overwrite effect flags from an earlier object. Invisible zones merge their flags differently. This makes final effects dependent on draw order.

### Blur Is Expensive And Not Actually Separable

The fragment shader's `fastBlur` samples in both X and Y inside one function. It is not a two-pass separable blur despite its comment. A pixel with multiple effect flags can call it multiple times. This is expensive as effect coverage grows.

### Dissolve Alpha Does Not Necessarily Hide Pixels

The dissolve effect sets `result.a = 0.0`, but the current GL bindings and rendering code do not enable blending. Alpha in a fragment output does not automatically reveal the cleared framebuffer. Use `discard` for a cutout dissolve or explicitly enable/configure blending.

## Recommended Render Layers

Move toward explicit layers:

```text
sky layer             persistent and mostly static
material-world layer  persistent cells/chunks
actor layer           cleared each frame: player, jelly, bullets, particles
debug layer           optional and cleared each frame
effect mask           flags/intensity, cleared each frame
post-processing       GPU composition and optional downsampled passes
```

The immediate version can still compose world pixels into the existing `pixel_buffer` on CPU, then draw actors. Later, upload material chunks directly into a dedicated world texture and compose in the shader.

## Dirty Chunk Rendering

When the material world is chunked, render each dirty chunk into its CPU chunk pixel storage and upload only that region with `glTexSubImage2D`.

Benefits:

- no full world-color upload when only a few chunks changed
- natural fit for cellular terrain activity
- chunk rendering is parallelizable in the future

Do not add persistent mapped buffers or PBOs until profiling proves full uploads are the limiting cost. Dirty rectangles are the simpler first optimization.

## Post-Processing Direction

Keep simple local effects in the final composite shader:

- heat distortion
- chromatic shift
- color grading
- palette/lighting transforms

Move broad blur/bloom into dedicated passes:

```text
scene -> downsample bright areas -> horizontal blur -> vertical blur -> composite
```

Perform blur at half or quarter resolution. This is both faster and visually more coherent than a large blur kernel in the final full-resolution shader.

---

# Part V: Target Hybrid Model

## Clear Ownership Table

| Domain | Simulation model | Examples | Primary state |
| --- | --- | --- | --- |
| Player | Kinematic controller | movement, jumps, recoil | `Position`, controller velocity/state |
| Projectile/debris | Velocity dynamics | bullets, grenades, explosion pieces | `Position`, `Velocity`, `PhysicsBody` |
| Creature deformation | Verlet/PBD | jelly core, limbs, ropes, cloth | `Position`, previous position, constraints |
| Static terrain | Material grid plus extracted colliders | rock, indestructible world | chunk cells, optional collider cache |
| Loose materials | Cellular automata | sand, water, smoke, fire | material cells and active chunks |
| Visual effects | GPU post-process | heat haze, bloom, distortion | textures and effect masks |

No system should silently become the authority for another domain. The player can push a jelly core through an explicit player-to-Verlet contact policy. A bullet can carve rock through a material edit operation. These bridges are intentional integrations, not shared ownership.

## Proposed Fixed-Step Simulation Phases

For each fixed step:

```text
1. Read sampled input and apply player/gameplay intent.
2. Advance conventional velocity bodies.
3. Sweep bullets through terrain and resolve impacts.
4. Predict Verlet particle positions.
5. Repeat N solver iterations:
   - solve jelly attachments
   - solve Verlet terrain contacts
   - solve player-to-landable-core contact
   - solve Verlet self collision
6. Update active material chunks.
7. Apply gameplay consequences: destruction, damage, spawning, cleanup.
8. Mark terrain/render chunks dirty.
```

This ordering is a guide, not a law. The critical properties are:

- all PBD constraints share a solver loop
- bullets use swept tests before they can tunnel
- material changes become world state before render
- gameplay events are not interwoven into every low-level collision loop

---

# Part VI: Staged Roadmap

## Phase 0: Stabilize The Current Prototype

1. Make `playerTouchesLandable` require a top-facing manifold normal.
2. Keep `PlayerLandable` skipping only the old player-repulsion branch, never terrain contact.
3. Remove empty placeholder systems such as `seek_system`, or give them a defined role.
4. Remove or implement unused physics fields/constants.
5. Replace fixed `[64]` destruction queues with a frame arena list, then profile.
6. Add debug counters: ground checks, Verlet contacts, self-contact pairs, bullet hits, and frame solver time.

Success condition: current player/jelly/terrain behavior remains stable and observable before new features are added.

## Phase 1: Fixed Step And PBD Contact Loop

1. Add fixed-step accumulator in `main`.
2. Separate Verlet prediction from solving.
3. Move attachments, terrain, player-core, and self collision into a repeated solver phase.
4. Name every Verlet translation/impulse policy.
5. Tune gravity and damping only after frame-rate independence is verified.

Success condition: a jelly behaves consistently at 30, 60, and 120 FPS, and strong contact does not permanently stretch it.

## Phase 2: Material World Prototype

1. Create `src/engine/material_world.zig` or `src/game/material_world.zig`.
2. Implement chunk allocation, `getCell`, `setCell`, and circular carve operations.
3. Convert one test platform from ECS tile entities to rock cells.
4. Render material cells into a persistent world buffer.
5. Implement bullet DDA against the material grid.
6. Retire `restoreRect` from terrain destruction.

Success condition: bullets carve visible holes in rock without creating/deleting tile ECS entities.

## Phase 3: Terrain Collision Migration

1. Let player collision query material rock cells or extracted chunk rectangles.
2. Let Verlet terrain contact query the same world representation locally.
3. Keep static wall/floor ECS colliders temporarily where convenient.
4. Remove `GroundGrid` entity generation once equivalent material collision exists.

Success condition: terrain cost is proportional to nearby chunks/cells, not total map tile count.

## Phase 4: Sand And Water

1. Add active chunks and bottom-up sand movement.
2. Add water flow and material swapping.
3. Add chunk-border updates and deterministic iteration direction.
4. Add falling debris conversion when rock is destroyed.
5. Profile active-cell update count and dirty GPU upload count.

Success condition: several thousand active cells can run at the target simulation rate without stalls.

## Phase 5: Rendering Improvements

1. Separate scene/world/actor/effect responsibilities.
2. Define deterministic effect-mask blend rules.
3. Upload material-world dirty regions rather than full world color each frame.
4. Move bloom/blur to reduced-resolution two-pass shaders.
5. Add real alpha composition or use `discard` for cutout effects.

Success condition: terrain changes remain visually persistent and post-processing cost scales predictably.

---

# Part VII: References And Concepts To Study

## Position Based Dynamics And Verlet

- Thomas Jakobsen, "Advanced Character Physics"
- Matthias Muller et al., "Position Based Dynamics"
- Extended Position Based Dynamics (XPBD) for stiffness that is less timestep dependent

Study topics:

- Verlet integration
- distance constraints
- iterative Gauss-Seidel constraint solving
- positional contact constraints
- compliance and stiffness
- inverse mass weighting

## Traditional Collision And CCD

- Erin Catto / Box2D presentations and manual
- Gaffer on Games collision response articles
- Amanatides and Woo grid traversal / DDA

Study topics:

- manifolds, normals, and penetration depth
- broadphase spatial hashing
- swept tests and time of impact
- kinematic versus dynamic bodies
- impulse response versus positional correction

## Cellular Materials

- Falling-sand cellular automata techniques
- active-set and chunked simulation designs
- dirty rectangle texture updates

Study topics:

- update order bias
- double buffering versus update stamps
- material density swaps
- active chunk propagation
- deterministic randomization

## Profiling Rule

Do not adopt an optimization because it sounds engine-like. First add counters and measure:

- fixed steps per rendered frame
- active material cells/chunks
- collision candidates versus actual contacts
- solver iteration time
- full/dirty texture upload bytes
- time spent in CPU drawing and GPU presentation

The engine should get more elaborate only when measurement names the next bottleneck.
