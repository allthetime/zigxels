# World Reset And Entity Lifecycle Plan

## Purpose

This document defines how entities should be owned, deleted, and recreated when the game world resets.

The immediate bug is that creatures survive reset. The wider cause is that reset behavior is based on several special-case queries instead of a consistent ownership model.

The target is simple:

```text
reset = delete resettable groups + restore persistent player state + respawn level content
```

Every entity should answer one lifecycle question:

> Who owns this entity, and should that owner survive a world reset?

## Current Reset Behavior

`reset_game` currently does the following:

1. Deletes entities that are `ChildOf(BulletsGroup)`.
2. Moves the player to the default position and clears player `Velocity`.
3. Deletes entities that are `ChildOf(GroundGroup)`.
4. Deletes all entities carrying `Ground`.
5. Restores the sky into `background_buffer`.
6. Calls `spawn_level`.

This handles bullets and terrain, but creatures are spawned independently in `spawn_initial_entities`. Jelly center/skin particles have no level-creature parent and reset never selects their `VerletState` entities for deletion or reinitialization.

The player tail has a related issue: its particles are not currently children of the player. The player moves back to spawn, but tail particles retain old positions and Verlet history.

## Lifecycle Categories

Use these categories consistently.

| Category | Examples | Reset behavior | Owner |
| --- | --- | --- | --- |
| Persistent session state | ECS queries, input singleton, engine buffers/configuration | Keep | World/singleton |
| Persistent actor | Player entity | Keep, restore state | `PlayerContainer` |
| Player equipment/attachments | Gun, tail, future player-owned rope | Delete and recreate, or explicitly restore all state | Player |
| Level terrain | Ground tiles, walls, material chunks | Delete and recreate | `GroundGroup` / level root |
| Level creatures | Jelly, eel, caterpillar, enemies | Delete and respawn | `CreatureGroup` |
| Transient entities | Bullets, explosion particles, temporary effects | Delete | `BulletsGroup` / transient root |
| UI/debug entities | Mouse cursor, editor markers | Keep or refresh independently | UI/debug root |

The important distinction is between **persistent roots** and their **resettable descendants**. A resettable child should always have a path to a root that reset knows how to clear.

## Root Groups

The project already uses these roots:

```text
BulletsGroup
GroundGroup
PlayerContainer
```

Add a root for level creatures:

```zig
pub const CreatureGroup = struct {
    entity: ecs.entity_t,
};
```

This singleton is analogous to `GroundGroup` and `BulletsGroup`.

### Initial Creation

Create group roots once during initial setup. The group entity itself survives reset; only its children are deleted.

```zig
const creature_group = ecs.new_entity(world, "Creatures");
_ = ecs.singleton_set(world, C.CreatureGroup, .{
    .entity = creature_group,
});
```

Register `CreatureGroup` with the other singleton components before calling `ecs.singleton_set`.

## Child Ownership Rules

`ChildOf` should express lifecycle ownership for all spawned entities.

### Bullets

Already correct:

```text
bullet -> ChildOf(BulletsGroup)
```

### Terrain

The grid grouping is a child of `GroundGroup`, and grid tiles are children of that grouping. This supports a recursive conceptual hierarchy:

```text
GroundGroup
  GroundGrid
    tile
    tile
```

Walls/floor are currently tagged `Ground` but not children of `GroundGroup`; the fallback `ecs.delete_with(world, ecs.id(C.Ground))` removes them. Over time, make every terrain entity a direct or indirect child of `GroundGroup`, then remove the broad tag deletion.

### Creatures

Every creature particle must be a child of `CreatureGroup` while it is level-owned:

```text
CreatureGroup
  jelly center
  jelly skin particle
  eel head
  eel joint
  caterpillar leg particle
```

For a generic creature spawner, it is useful to create a creature root as an intermediate owner:

```text
CreatureGroup
  CreatureRoot
    particle 0
    particle 1
    particle 2
```

The root may later carry enemy health, behavior state, AI target, and spawn metadata. It does not need a collider or `VerletState`.

### Player-Owned Attachments

Every player attachment should use:

```text
gun -> ChildOf(Player)
tail segment -> ChildOf(Player)
```

This includes existing tail nodes in `spawn_player_tail`:

```zig
ecs.add_pair(world, seg, ecs.ChildOf, player);
```

The player body itself must not be its own child. The player survives reset; its attachments do not.

## Spawn Function Boundaries

Avoid having `spawn_initial_entities` directly create every level object. Split ownership-based spawning into functions.

```zig
fn spawn_player(world: *ecs.world_t, engine: *engine_mod.Engine) ecs.entity_t;
fn spawn_player_attachments(world: *ecs.world_t, player: ecs.entity_t) void;
fn spawn_level(world: *ecs.world_t, engine: *engine_mod.Engine) void;
fn spawn_level_creatures(world: *ecs.world_t, engine: *engine_mod.Engine) void;
```

Then initial setup becomes:

```text
create persistent group roots
spawn player
spawn player attachments
spawn level
spawn level creatures
create cached physics queries
```

The reset path invokes only the resettable portions.

## Creature Spawn API

Creature spawners must receive an owner. Do not let them create unowned particles.

Current direct function:

```zig
fn spawn_jelly_blob(world, cx, cy, radius, segments) void
```

Target form:

```zig
fn spawn_jelly_blob(
    world: *ecs.world_t,
    owner: ecs.entity_t,
    cx: f32,
    cy: f32,
    radius: f32,
    segments: usize,
) void
```

Immediately after creating each center/skin particle:

```zig
ecs.add_pair(world, particle, ecs.ChildOf, owner);
```

The future generic `spawnCreature` follows the same contract:

```zig
fn spawnCreature(
    world: *ecs.world_t,
    owner: ecs.entity_t,
    origin: C.Position,
    definition: CreatureDefinition,
) ecs.entity_t
```

It can create a `CreatureRoot` child of `owner`, then make all Verlet particles children of that root.

## Reset Algorithm

The reset must not reconstruct ECS component registrations or cached query objects. It only changes runtime entities and world pixels.

Recommended order:

```text
1. Delete transient entities.
2. Delete level creature entities.
3. Delete player attachments.
4. Delete level terrain entities.
5. Restore persistent rendering/world state.
6. Restore player position and controller state.
7. Spawn player attachments.
8. Spawn level terrain.
9. Spawn level creatures.
```

In code:

```zig
fn reset_game(world: *ecs.world_t, engine: *engine_mod.Engine) void {
    if (ecs.singleton_get(world, C.BulletsGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }

    if (ecs.singleton_get(world, C.CreatureGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }

    const player = ecs.singleton_get(world, C.PlayerContainer).?.entity;
    ecs.delete_with(world, ecs.pair(ecs.ChildOf, player));

    if (ecs.singleton_get(world, C.GroundGroup)) |group| {
        ecs.delete_with(world, ecs.pair(ecs.ChildOf, group.entity));
    }

    // Temporary migration safeguard until all terrain has GroundGroup ownership.
    ecs.delete_with(world, ecs.id(C.Ground));

    @memcpy(engine.background_buffer, engine.sky_buffer);

    _ = ecs.set(world, player, C.Position, .{
        .x = @as(f32, @floatFromInt(engine.width)) / 2.0,
        .y = @as(f32, @floatFromInt(engine.height)) / 2.0,
    });
    _ = ecs.set(world, player, C.Velocity, .{ .x = 0.0, .y = 0.0 });
    _ = ecs.set(world, player, C.RecoilImpulse, .{ .x = 0.0 });

    spawn_player_attachments(world, player);
    spawn_level(world, engine);
    spawn_level_creatures(world, engine);
}
```

### Why Delete And Respawn Creatures?

A Verlet creature has state in both its current position and previous position. Resetting only `Position` leaves old positions behind, which creates a large implicit velocity on the next Verlet integration step.

Deleting and respawning guarantees every particle begins with:

```text
Position == old_position
```

That is simpler and less error-prone than a custom reset function that must update position, old position, constraints, drives, hit state, AI state, and render state for every current and future creature type.

## Why Delete And Respawn Player Attachments?

The same Verlet-history rule applies to player tails and any future flexible equipment. Deleting player children then rebuilding the gun/tail starts them in a coherent state at the reset player position.

The player itself remains stable because its `Position`, `Velocity`, and `RecoilImpulse` are explicitly reset.

## Migration Steps

### Step 1: Add Creature Group

1. Define and register `CreatureGroup`.
2. Create its root during initial setup.
3. Add a `spawn_level_creatures` function.
4. Move the existing `spawn_jelly_blob` call into that function.

Checkpoint: calling `spawn_level_creatures` once produces the same jelly as before.

### Step 2: Give Jelly Particles Ownership

1. Add an `owner` argument to `spawn_jelly_blob`.
2. Mark center and every skin node `ChildOf(owner)`.
3. Pass `CreatureGroup.entity` from `spawn_level_creatures`.

Checkpoint: `ecs.delete_with(world, ecs.pair(ecs.ChildOf, creature_group))` removes every jelly particle.

### Step 3: Reset And Respawn Creatures

1. Delete `CreatureGroup` children near the start of `reset_game`.
2. Call `spawn_level_creatures` after terrain respawns.

Checkpoint: pressing reset creates one fresh jelly at its spawn point, with no duplicate or remaining particles.

### Step 4: Fix Player Attachment Ownership

1. Add `ChildOf(player)` to every tail segment.
2. Extract gun and tail creation into `spawn_player_attachments`.
3. Delete player children in `reset_game`.
4. Respawn attachments after restoring player state.

Checkpoint: reset reconstructs exactly one gun and one tail; tail particles begin around the player rather than at their prior world position.

### Step 5: Complete Terrain Ownership

1. Make walls, floor, and effect zones children of `GroundGroup` or a broader `LevelGroup`.
2. Confirm `GroundGroup` deletion removes all level terrain/effects.
3. Remove the fallback `ecs.delete_with(world, ecs.id(C.Ground))`.

Checkpoint: all resettable level content is selected through explicit ownership, not broad component deletion.

## Verification Checklist

1. Start the game and count visible jelly particles.
2. Let the jelly fall, deform, and receive bullet/player interactions.
3. Press reset repeatedly.
4. Confirm exactly one fresh creature spawns per level creature definition.
5. Confirm no old creature particles remain on screen or in debug collider drawing.
6. Confirm player tail/gun do not duplicate and are positioned relative to the reset player.
7. Confirm bullets and explosion particles disappear.
8. Confirm terrain returns to its original visual state.

## Long-Term Direction: Level Root

Once the project has multiple resettable categories, consider a single `LevelRoot` with child roots:

```text
LevelRoot
  TerrainRoot
  CreatureRoot
  TransientRoot
  EffectRoot
```

Then a world reset can delete all `ChildOf(LevelRoot)` descendants and respawn the level. Keep the player, UI, input, engine, and cached queries outside this root.

Do not adopt this immediately if the separate group roots are clearer during development. The essential requirement is not the number of roots; it is that every resettable entity has explicit ownership.