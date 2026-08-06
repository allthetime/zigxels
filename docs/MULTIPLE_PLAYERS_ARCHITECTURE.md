# Multiple Players Architecture

## Purpose

This document outlines how the current single-player prototype can evolve to support multiple local players and, later, networked players.

The goal is not to make every system network-aware immediately. The immediate goal is to make player identity, input, camera selection, weapons, and player-specific attachments explicit instead of assuming that `PlayerContainer` identifies the only player in the world.

## Current Single-Player Assumptions

The current implementation uses these global assumptions:

- `PlayerContainer` stores one player entity.
- `AimTarget` is one singleton value.
- `InputState` is one singleton value.
- the gun is a `ChildOf` that one player.
- player tails and player-landable contact code retrieve the one player through `PlayerContainer`.
- the camera is implicitly centered on the one logical screen rather than following a world entity.

This is appropriate for a prototype. It becomes limiting as soon as two players need different input, aim, guns, recoil, or cameras.

## Design Principle

Replace global "the player" state with per-player state.

```text
single-player assumption: singleton -> player entity
multi-player model:       player entity -> player-specific components
```

There can still be global state for the game world, simulation tick, level, and shared camera mode. There should not be global state for a player's movement input, aim target, equipment, or controller assignment.

## Player Entity Model

Each controllable player entity should own the components needed for its controller and presentation.

```text
Player
  Position
  Velocity
  Collider
  RecoilImpulse
  PlayerInput
  AimTarget
  PlayerSlot
  PlayerCameraTarget
  PlayerState (optional: health, lives, team)
```

Suggested components:

```zig
pub const PlayerSlot = struct {
    index: u8,
};

pub const PlayerInput = struct {
    move_x: f32 = 0.0,
    move_y: f32 = 0.0,
    jump_pressed: bool = false,
    fire_pressed: bool = false,
};

pub const PlayerAim = struct {
    x: f32,
    y: f32,
};
```

`PlayerSlot` is not necessarily a network identifier. It maps a local input source to a player in local cooperative or versus play.

## Input Routing

The platform layer should continue to collect raw keyboard, mouse, and controller state. A separate system then assigns input to each player based on `PlayerSlot`.

```text
SDL input devices
        |
        v
input routing system
        |
        +--> PlayerInput + PlayerAim on player 0
        +--> PlayerInput + PlayerAim on player 1
        +--> PlayerInput + PlayerAim on player 2
```

For example:

| Slot | Input source | Aim source |
| --- | --- | --- |
| 0 | keyboard | mouse |
| 1 | controller 0 | right stick |
| 2 | controller 1 | right stick |

Do not make the player controller inspect global keyboard/controller state directly. It should only read the `PlayerInput` and `PlayerAim` belonging to the current entity.

## Controller System Change

The player controller currently receives `Player`, `Position`, `Velocity`, `Collider`, and `RecoilImpulse`. Extend that query to receive `PlayerInput`.

```text
for each Player:
  read that player's PlayerInput
  update that player's velocity
  move that player's collider
  resolve that player's terrain contacts
```

Every player should be processed by the same system. Do not create `player_one_controller_system` and `player_two_controller_system`.

## Per-Player Aim And Weapons

Replace the `AimTarget` singleton with `PlayerAim` attached to each player. A gun should remain a child of its owner:

```text
player A
  gun A
player B
  gun B
```

The gun aim system should find its parent player and read that player's `PlayerAim`.

Similarly, firing should create bullets under the global transient/bullet root, while storing the shooter entity when friendly-fire, scoring, or recoil needs attribution:

```zig
pub const ProjectileOwner = struct {
    entity: ecs.entity_t,
};
```

This lets projectile logic ignore the shooter's collider briefly after spawn and supports teams later.

## Player Attachments And Reset

Every player-owned object is a `ChildOf(player)`:

```text
player
  gun
  tail segments
  shield effect
  held object
```

On reset, either restore attachment state explicitly or delete/recreate that player's children. For Verlet attachments, delete/recreate is safer because `Position` and `VerletState.old_position` must reset together.

```text
for each player:
  delete ChildOf(player)
  restore player position/state
  spawn that player's attachments
```

## Player And Creature Contacts

`PlayerLandable` should not retrieve one singleton player. Instead, the player controller for each player queries or iterates landable entities.

```text
for each player:
  resolve player versus static terrain
  resolve player versus PlayerLandable Verlet cores
```

This preserves the current contact ownership rule: the kinematic player controller owns player-to-landable response. It simply runs once per player.

If players need to collide with one another, add a separate player-versus-player contact pass. Decide the intended rule first:

- pass through: no player/player contact
- soft push: positional correction split between both players
- solid platforms: a more deliberate ordering and grounded-contact policy

Do not accidentally use `PlayerLandable` to make players stand on each other.

## Camera Choices

Multiple players introduce a game-design decision before a rendering problem.

### Shared Camera

One camera tracks the average or bounds of all live players. It is the simplest option.

Use it when:

- the players should stay near each other
- the game is cooperative
- the playable region is compact

Set a maximum player separation. When exceeded, constrain movement, pull players together, or choose another mode intentionally.

### Split Screen

Each player gets an independent camera/viewport.

Use it when:

- players may explore separately
- local versus play matters
- the renderer can draw the world more than once per frame

This requires camera-relative rendering and viewport/scissor support. Build world-space rendering first; do not add split screen to the current screen-space architecture.

### Dynamic Merge/Split

The game uses a shared camera when players are near and split viewports when they separate. This is expressive but substantially more complex. Treat it as a later product feature, not the first multiple-player milestone.

## Networking Boundary

Local multi-player and networked multi-player share the need for per-player state, but they are not the same engineering task.

First establish:

- fixed-timestep simulation
- deterministic or at least reproducible player input application
- player-specific input components
- explicit projectile ownership
- no singleton player assumptions

Then choose a network model:

| Model | Best for | Tradeoff |
| --- | --- | --- |
| Client/server snapshots | action games with authoritative host | interpolation, prediction, reconciliation work |
| Lockstep | deterministic games with low input bandwidth | strict determinism requirement |
| Peer-to-peer rollback | fast competitive games | complicated synchronization and determinism requirements |

The current variable timestep and CPU-side unconstrained physics are not ready for network synchronization. Do not add networking before the fixed-step milestone in the main architecture roadmap.

## Migration Steps

### Step 1: Introduce Per-Player Input

1. Add `PlayerSlot`, `PlayerInput`, and `PlayerAim`.
2. Copy current singleton input/aim values to player 0 each frame.
3. Update controller/gun systems to read player-owned data.
4. Keep `PlayerContainer` temporarily for spawn/reset lookup only.

Checkpoint: one player behaves identically, with no movement or aiming singleton consumed by gameplay systems.

### Step 2: Spawn A Second Local Player

1. Spawn another entity with the same player component set.
2. Give it `PlayerSlot { .index = 1 }`.
3. Route controller 0 input to player 1.
4. Spawn a gun and attachments as its children.

Checkpoint: both players move, aim, shoot, reset, and maintain separate recoil state.

### Step 3: Remove Single-Player Lookup

1. Replace `PlayerContainer` reads in contact and behavior systems with player queries.
2. Preserve it only if a game mode needs a designated primary player.
3. Otherwise remove it.

Checkpoint: adding a third player requires no gameplay code changes.

### Step 4: Add Camera Policy

1. Implement one world-space camera.
2. Use a shared camera that follows all players.
3. Add split screen only after world-space rendering is established and measured.

## Success Criteria

- The same player controller system updates every player.
- Every player has independent input, aim, recoil, equipment, and reset state.
- Bullets identify their owner when needed.
- Player-owned Verlet attachments reset without stale implicit velocity.
- Creature/player contacts do not assume a singleton player.
- The camera behavior is an explicit game-mode decision rather than an accidental screen-space limitation.