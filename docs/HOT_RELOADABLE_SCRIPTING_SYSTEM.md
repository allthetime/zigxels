# Hot-Reloadable Gameplay Scripting System

## Purpose

This document describes a scripting system for authoring high-level gameplay without rebuilding the Zig executable after every behavior change.

The intended uses include:

- creature AI and attack patterns
- level triggers and encounters
- mission/objective rules
- pickups, doors, switches, and checkpoints
- material reactions authored at a high level
- temporary prototype mechanics
- debug commands and developer tools

The scripting layer should not replace the physics, ECS, renderer, or material simulation. It should orchestrate those reliable native systems.

```text
Zig engine: simulation, rendering, ECS, memory ownership, collision, materials
scripts:    decisions, parameters, sequencing, content, event reactions
```

## Design Goals

- Change high-level gameplay without recompiling the executable.
- Reload scripts safely during development.
- Preserve native ownership of performance-critical simulation.
- Expose a small, deliberate API rather than raw ECS pointers.
- Keep script failure contained and visible.
- Support later save/load and optional deterministic simulation.
- Avoid requiring scripts for basic engine boot, rendering, or low-level physics.

## Non-Goals

The first scripting system should not attempt to:

- rewrite the renderer from scripts
- run per-material-cell sand simulation in a dynamic language
- expose raw `*ecs.world_t` or unsafe native pointers
- support arbitrary native memory access
- provide automatic multiplayer determinism
- preserve every local variable across all possible code reloads

The system is a gameplay-control layer, not a second engine.

## Language Choice

The best initial choice is Lua, embedded through a maintained Zig binding or a small C API wrapper.

Lua is appropriate because it has:

- fast startup and compact embedding surface
- familiar syntax for gameplay authors
- a mature ecosystem of game-engine patterns
- straightforward file-based reload
- coroutines for sequence/encounter scripting later
- a stable C API that fits Zig well

Other viable options:

| Option | Strength | Main cost |
| --- | --- | --- |
| Lua | mature embedded game scripting | needs binding/API design |
| Wren | pleasant small OO language | less ubiquitous integration ecosystem |
| Rhai | Rust-oriented scripting | not a natural Zig embedding path |
| JavaScript | familiar syntax | heavier runtime and larger embedding surface |
| Zig plugins/dylibs | native performance/type access | hard reload/lifetime/ABI problems |

Do not begin with dynamic Zig library hot reload. Native ABI stability, allocator ownership, function pointers, and unloading code that still owns state make it far more fragile than a scripting VM. Lua makes iteration easy while the native engine stays compiled and safe.

## Architectural Boundary

Scripts communicate through stable handles and commands.

```text
Lua script
   |
   | engine API calls and event callbacks
   v
Script bridge in Zig
   |
   | validates arguments and enqueues commands
   v
ECS / material world / game systems
```

The bridge must not hand scripts mutable ECS component pointers. Scripts should request or command meaningful game operations:

```lua
local target = game.find_nearest_player(self, 320)
game.creature.reach(self, target, 1.4)
game.creature.set_link_stiffness(self, "body", 0.75)
game.spawn.projectile(self, "acid_blob", direction, 900)
game.material.carve_circle(hit_x, hit_y, 8, "rock")
```

Zig validates the handle, arguments, and permitted operation before changing world state.

## Entity Handles

ECS entity IDs can be exposed as opaque script values, but they must never become raw pointers.

```zig
pub const ScriptEntity = struct {
    id: ecs.entity_t,
};
```

Script-facing API conventions:

- entity-returning calls yield `nil` when no valid entity exists
- every native call validates that the entity is still alive
- scripts cannot manufacture entity IDs from arbitrary integers
- destroyed entities become invalid handles

Example Lua use:

```lua
function on_update(self, dt)
    local player = game.find_nearest_player(self, 480)
    if player ~= nil then
        game.creature.reach(self, player, 1.2)
    end
end
```

## Script Components

Attach a lightweight native component to entities that have behavior authored in scripts.

```zig
pub const ScriptBehavior = struct {
    asset_id: ScriptAssetId,
    instance_id: u32,
    enabled: bool = true,
};
```

The component identifies the script asset and runtime instance. It should not embed arbitrary Lua state directly in ECS component memory.

The script runtime owns per-instance Lua tables:

```text
entity 1042 -> scripts/creatures/jelly.lua -> Lua instance table
entity 1051 -> scripts/levels/door.lua       -> Lua instance table
```

## Script Lifecycle

Use explicit lifecycle callbacks. The first useful set is:

```lua
function on_spawn(self)
end

function on_update(self, dt)
end

function on_event(self, event)
end

function on_despawn(self)
end
```

Suggested semantics:

| Callback | Runs when | Appropriate work |
| --- | --- | --- |
| `on_spawn` | entity instance is created | initialize script state, select parameters |
| `on_update` | once per fixed simulation step | decisions, timers, high-level commands |
| `on_event` | native system sends an event | react to hit, trigger, pickup, death |
| `on_despawn` | entity is removed | stop effects, release script-only state |

Scripts should not poll every possible world condition every frame. Prefer events for sparse facts such as hit, entered trigger, destroyed terrain, or target death.

## Events

Native systems emit game events into a queue. The script runtime dispatches them after the native system phase that produced them.

```zig
pub const GameEvent = union(enum) {
    hit: struct { source: ecs.entity_t, target: ecs.entity_t, damage: f32 },
    trigger_entered: struct { trigger: ecs.entity_t, actor: ecs.entity_t },
    projectile_impacted: struct { projectile: ecs.entity_t, x: f32, y: f32 },
    material_changed: struct { chunk_x: i32, chunk_y: i32 },
    entity_destroyed: struct { entity: ecs.entity_t },
};
```

Lua receives a read-only event table:

```lua
function on_event(self, event)
    if event.kind == "hit" then
        game.effects.flash(self, "white", 0.1)
    end
end
```

Do not call scripts immediately from the deepest collision loop. Queue events and dispatch them at a controlled point. This prevents re-entrant ECS mutation and makes ordering understandable.

## Commands, Not Immediate Structural Mutation

Scripts should request state changes through a command buffer.

```text
script callback
  -> validates API call
  -> appends command
  -> callback finishes
  -> native command application phase mutates ECS/material world
```

Examples:

```zig
pub const ScriptCommand = union(enum) {
    spawn_prefab: struct { prefab: PrefabId, x: f32, y: f32, owner: ecs.entity_t },
    destroy_entity: struct { entity: ecs.entity_t },
    set_reach_target: struct { entity: ecs.entity_t, target: ecs.entity_t, stiffness: f32 },
    carve_material: struct { x: f32, y: f32, radius: f32, material: Material },
    play_effect: struct { effect: EffectId, x: f32, y: f32 },
};
```

This protects ECS iteration. It also creates a future hook for replay, debugging, command inspection, and network authority.

## Script API Layers

Keep the initial API narrow and grouped by ownership domain.

### Query API

Read-only facts:

```lua
game.entity.position(entity)
game.entity.is_alive(entity)
game.find_nearest_player(origin, radius)
game.world.time()
game.world.random(entity, salt)
```

### Creature API

High-level actions, not low-level particle pointers:

```lua
game.creature.reach(creature, target, stiffness)
game.creature.set_mode(creature, "aggressive")
game.creature.apply_impulse(creature, x, y)
```

For arbitrary Verlet creatures, a script can target named attachment points defined by creature data. It should not individually manipulate all particles by default.

### World API

```lua
game.material.carve_circle(x, y, radius, "rock")
game.world.spawn("enemy_eel", x, y)
game.world.open_door(door)
game.world.set_checkpoint(checkpoint)
```

### Presentation API

```lua
game.effects.flash(entity, "cyan", 0.12)
game.effects.emit("impact_sparks", x, y)
game.audio.play("jelly_hit", x, y)
```

Presentation commands should be safe to ignore in headless tests and later network servers.

## Hot Reload

Hot reload means a modified script file changes future behavior without rebuilding the Zig executable or restarting the game.

### Development Loop

```text
edit scripts/creatures/eel.lua
      |
file watcher marks asset dirty
      |
end of current simulation step
      |
compile/load replacement Lua chunk
      |
validate required callbacks
      |
replace asset implementation
      |
migrate live entity instances
```

Reload only at a known safe point between simulation steps. Do not unload a script while one of its callbacks is executing.

### Asset Registry

Maintain a native registry:

```zig
pub const ScriptAsset = struct {
    path: []const u8,
    version: u32,
    loaded_at: i128,
    lua_registry_ref: i32,
    last_error: ?[]const u8,
};
```

The registry maps a stable asset ID/path to the currently loaded Lua module. `ScriptBehavior.asset_id` refers to this registry entry, not directly to a transient Lua function pointer.

### Reload Strategy: Replace Behavior, Preserve Explicit State

The safest first model is:

1. serialize selected script instance state into a Lua/Zig value tree
2. load and validate the replacement module
3. create a new instance table for each affected entity
4. call optional `on_reload(self, old_state)`
5. replace the old instance only when migration succeeds

Example:

```lua
function save_state(self)
    return {
        cooldown = self.cooldown,
        mood = self.mood,
    }
end

function on_reload(self, old_state)
    self.cooldown = old_state.cooldown or 0
    self.mood = old_state.mood or "idle"
end
```

Do not try to preserve arbitrary Lua closures, coroutine stacks, userdata, or references across reload. Explicit state migration is predictable and encourages scripts to keep durable state simple.

### Reload Failure Policy

A bad script reload must not take down the game.

1. Compile/load new source into a temporary Lua module.
2. Validate its required functions.
3. If validation fails, retain the old working module.
4. Record/display the error and file/line.
5. Continue running the current game.

If an individual callback fails at runtime, disable only that behavior instance, log the error, and retain the rest of the world. In development, show a visible error indicator for the affected entity.

## Script State And Save Games

Script state must be serializable if level chunks, checkpoints, or save games need to preserve it.

Allow only simple state values:

- nil
- booleans
- numbers
- strings
- arrays
- tables whose keys are strings/integers and whose values are also allowed values
- entity handles encoded through a validated ID/reference form

Reject or avoid:

- functions
- userdata
- open file handles
- threads/coroutines in saved state
- arbitrary cyclic tables

The same constrained state representation supports save/load and hot reload.

## Coroutines

Lua coroutines are useful for high-level sequences:

```lua
function on_spawn(self)
    game.start_coroutine(self, function()
        game.wait_seconds(1.0)
        game.world.spawn("enemy_eel", 200, 120)
        game.wait_until(function()
            return game.enemy_count() == 0
        end)
        game.world.open_door(self)
    end)
end
```

Do not add coroutines in the first implementation. Start with `on_update`, timers, and events. Coroutines need explicit cancellation on reset/despawn/reload and a defined serialization policy.

## Fixed Timestep And Determinism

Script `on_update(self, dt)` should run once per fixed simulation step, not once per rendered frame. This follows the same requirement as Verlet stability.

Scripts must not read nondeterministic wall-clock time or call arbitrary random functions if deterministic replay/networking becomes a goal. Provide engine-controlled alternatives:

```lua
local tick = game.world.tick()
local roll = game.world.random(self, tick)
```

The initial script system does not need perfect cross-platform determinism, but its API should avoid making that impossible.

## Performance Rules

- Never call Lua once per material cell or once per pixel.
- Avoid one Lua callback per Verlet particle; scripts should control creature roots/high-level entities.
- Prefer event-driven logic to broad scanning from scripts.
- Put allocation-sensitive loops and collision broadphase in Zig.
- Cache resolved API functions and avoid string-based component lookup per update.
- Profile before optimizing the binding layer.

Typical good scripting frequency:

| Script target | Expected rate |
| --- | --- |
| Level director | infrequent/event driven |
| Enemy root AI | fixed step or reduced AI rate |
| Door/switch/pickup | event driven |
| Projectile | usually native system |
| Material cell | native system only |
| Renderer pixel/effect sample | native/GPU only |

## Security And Modding

Development scripts should be sandboxed even for a local game. Remove or avoid Lua libraries that permit unrestricted file, OS, debug, or native library access.

Expose file reads only through an asset loader if a script truly needs data. For user mods, add stronger limits:

- allowlisted asset paths
- instruction/time budgets per callback
- memory budget per script VM or instance set
- no arbitrary networking or process execution
- signed/validated package manifests if distribution needs trust

## Project Structure

Suggested layout:

```text
src/
  game/
    scripting.zig          Lua VM, asset registry, hot reload
    script_api.zig         native bindings and validation
    script_commands.zig    command buffer types/application
scripts/
  creatures/
    jelly.lua
    eel.lua
  levels/
    first_cavern.lua
  objects/
    door.lua
    checkpoint.lua
  prefabs/
    enemy_eel.lua
```

Keep script files outside `src/`; they are runtime content, not Zig source.

## Implementation Phases

### Phase 1: Embed Lua And Load One Module

1. Add a Lua dependency/binding through `build.zig.zon`.
2. Create one Lua VM owned by a `ScriptRuntime` singleton/resource.
3. Load a fixed test script from `scripts/`.
4. Expose one harmless function such as `game.log`.

Checkpoint: editing and manually reloading a script changes a log message without rebuilding Zig.

### Phase 2: Entity Script Behavior

1. Add `ScriptBehavior`.
2. Add `on_spawn` and `on_update` dispatch.
3. Expose read-only position and `find_nearest_player`.
4. Attach one script to a test creature root or trigger entity.

Checkpoint: a script can choose a target and request one native high-level behavior.

### Phase 3: Command Buffer And Events

1. Add `ScriptCommand` queue and apply phase.
2. Add native event queue and `on_event` dispatch.
3. Expose controlled spawn, destroy, effect, and material operations.
4. Remove direct structural ECS mutation from bindings.

Checkpoint: a scripted trigger can spawn an enemy, react to a hit, and carve terrain through queued native commands.

### Phase 4: File Watcher And Safe Reload

1. Watch the `scripts/` directory or poll modification timestamps in development builds.
2. Reload assets only between fixed steps.
3. Retain old module on compilation/validation failure.
4. Add visible, useful error reporting.

Checkpoint: saving a syntax-valid script changes live behavior; saving an invalid script reports an error while the old behavior keeps running.

### Phase 5: Explicit State Migration

1. Define allowed serializable script values.
2. Add optional `save_state` and `on_reload` callbacks.
3. Migrate instances belonging to a reloaded asset.
4. Add tests for entity destruction, reset, reload failure, and state migration.

Checkpoint: an enemy timer/state survives a valid behavior reload without retaining arbitrary unsafe VM state.

### Phase 6: Content Tools

1. Add prefab/level script conventions.
2. Add in-game reload command and script error panel.
3. Add debug inspection of attached behavior asset/state.
4. Consider coroutine support only after reset/reload cancellation is designed.

## Success Criteria

- Editing a gameplay script changes behavior without compiling Zig.
- Bad reloads leave the currently running game intact.
- Scripts use validated entity handles and a narrow API.
- Script callbacks enqueue commands rather than mutating ECS during arbitrary iteration.
- Collision, Verlet solving, materials, and rendering remain native.
- Script state has an explicit, testable save/reload policy.
- The scripting boundary does not prevent a fixed timestep, replay, or future multiplayer architecture.