# Arbitrary Verlet Creatures

## Purpose

This document defines a general way to construct creatures from Verlet particles, distance links, and drives. It is intended to support eels, caterpillars, jelly creatures, ropes, tentacles, and later cloth-like or multi-legged bodies without adding one-off physics components or systems for each creature type.

The engine owns generic simulation rules. A creature definition owns its shape and behavior configuration.

```text
generic engine: particle + collider + constraint + drive + contact
creature data:  node positions + radii + links + optional drives
```

## Design Goals

- Create new creatures by supplying data instead of new physics systems.
- Reuse `VerletState`, `AttachedTo`, `ReachTowards`, terrain collision, and rendering.
- Permit branching structures, not just chains.
- Allow particles of one creature to collide with themselves where useful.
- Prevent directly linked particles from fighting their own constraints.
- Keep creature-specific gameplay separate from low-level simulation.

## Current Generic Primitives

The project already has the basic pieces:

| Primitive | Existing component/system | Responsibility |
| --- | --- | --- |
| Particle position history | `VerletState` | Implicit velocity and damped motion |
| Visible/colliding body | `Position`, `Collider`, `Renderable`, `PhysicsBody` | Spatial presence and terrain response |
| Distance link | `(AttachedTo, target)` pair | Keeps two particles near a chosen separation |
| Target drive | `(ReachTowards, target)` pair | Moves one particle toward an entity |
| Generic solver | `attachment_solver_system` | Relaxes distance links |
| Generic contact | `verlet_collision_system` | Keeps particles out of terrain/player |
| Self contact | `verlet_self_collision_system` | Separates overlapping particles |

These should remain generic. There should be no `eel_physics_system`, `caterpillar_collision_system`, or creature-name-specific particle component.

## Ownership Model

A creature may have a root entity, but the root is for grouping and lifecycle only. It is not a physics body.

```text
CreatureRoot
  ChildOf
    particle 0
    particle 1
    particle 2
    ...
```

Use `ChildOf` to despawn the group and to inspect it in Flecs. Each particle remains a normal generic Verlet particle.

The root may later hold high-level state such as health, faction, AI intent, or animation/gait phase. Do not place collision solving or particle state on it unless a future profiling need justifies contiguous custom storage.

## Definition Data

The initial practical approach is a Zig definition built from node and link arrays. It can later come from a level file or editor.

```zig
const CreatureNode = struct {
    offset_x: f32,
    offset_y: f32,
    radius: f32,
    color: SDL.Color,
    friction: f32 = 0.985,
    restitution: f32 = 0.05,
    terrain_friction: f32 = 0.8,
};

const CreatureLink = struct {
    child_index: usize,
    parent_index: usize,
    distance: f32,
    stiffness: f32 = 0.9,
};

const CreatureDrive = union(enum) {
    reach_player: struct {
        node_index: usize,
        stiffness: f32,
    },
};

const CreatureDefinition = struct {
    nodes: []const CreatureNode,
    links: []const CreatureLink,
    drives: []const CreatureDrive,
};
```

This makes a creature a graph:

- a node is a Verlet particle
- a link is an `AttachedTo` constraint from child to parent
- a drive is an optional force/position influence on one node

The graph can be a chain, ring, tree, or a graph with multiple links per node.

## Generic Spawn Process

`spawnCreature(world, origin, definition)` should use this sequence:

1. Create a root entity.
2. Allocate a temporary array with one entity ID per definition node.
3. Create a normal Verlet particle for every node.
4. Add `ChildOf(root)` to every particle.
5. Add links after all particles exist, translating indices into entity IDs.
6. Add drives after all particles exist.
7. Return the root entity for lifecycle ownership.

The generic particle setup should always initialize:

```zig
Position
VerletState
Velocity       // required by the current integration query
Collider
PhysicsBody
Renderable
ChildOf(root)
```

The generic spawner should not decide whether a node is a head, leg, tail, or core. That information belongs in the definition or in a separate high-level gameplay component when it becomes necessary.

## Example: Eel

An eel is a simple chain with two large endpoints and smaller interior particles.

```text
tail -- joint -- joint -- joint -- head
                                  |
                              reaches player
```

The head is merely the final node in the definition and the target of a `reach_player` drive. It does not require an `EelHead` component.

```zig
const eel_nodes = [_]CreatureNode{
    .{ .offset_x = -80, .offset_y = 0, .radius = 14, .color = tail_color },
    .{ .offset_x = -60, .offset_y = 0, .radius = 5, .color = body_color },
    .{ .offset_x = -40, .offset_y = 0, .radius = 5, .color = body_color },
    .{ .offset_x = -20, .offset_y = 0, .radius = 5, .color = body_color },
    .{ .offset_x = 0, .offset_y = 0, .radius = 14, .color = head_color },
};

const eel_links = [_]CreatureLink{
    .{ .child_index = 1, .parent_index = 0, .distance = 20 },
    .{ .child_index = 2, .parent_index = 1, .distance = 20 },
    .{ .child_index = 3, .parent_index = 2, .distance = 20 },
    .{ .child_index = 4, .parent_index = 3, .distance = 20 },
};

const eel_drives = [_]CreatureDrive{
    .{ .reach_player = .{ .node_index = 4, .stiffness = 2.0 } },
};
```

The initial version will behave like a pulled rope. That is desirable. A more recognizably swimming eel should be created later by varying its link targets or applying phase-shifted lateral impulses, not by replacing the generic physics model.

## Example: Caterpillar

A caterpillar is a chain plus auxiliary particles. No new collision or constraint type is needed.

```text
       side node
          |
head -- body -- body -- body -- tail
          |
       side node
```

For each interior body node, define one or two auxiliary nodes and link them back to the body node with shorter, softer links.

```zig
.{ .child_index = left_leg_index, .parent_index = body_index, .distance = 14, .stiffness = 0.35 },
.{ .child_index = right_leg_index, .parent_index = body_index, .distance = 14, .stiffness = 0.35 },
```

Initially these are dangling side masses. Later, a high-level gait system may alternately push, retract, or change the preferred length of left/right links. The Verlet and collision systems remain unchanged.

## Example: Jelly

The existing jelly is a graph with:

- one central node
- multiple perimeter nodes
- a link from each perimeter node to the center
- links connecting adjacent perimeter nodes in a ring

It is already an example of a data-defined creature topology, even though it is currently created in a dedicated spawn function. Moving its node/link generation into a `CreatureDefinition` is a future refactor, not a prerequisite for an eel.

# Self-Collision

## Why It Exists

Distance constraints only preserve intended separations. They do not prevent distant parts of the same creature from occupying the same space.

Without self-collision:

- an eel can fold its head through its tail
- a jelly ring can collapse through itself
- caterpillar side nodes can pass through the body
- ropes can cross rather than bunching up

Self-collision treats overlapping particle colliders as a contact constraint and separates them.

For two circular particles with centers $p_1$ and $p_2$, radii $r_1$ and $r_2$, and distance $d$:

$$
overlap = (r_1 + r_2) - d
$$

When $overlap > 0$, move each particle away along the normalized direction between them. A basic equal-mass correction is:

$$
p_1 \mathrel{-}= n \cdot overlap / 2
$$

$$
p_2 \mathrel{+}= n \cdot overlap / 2
$$

## Why Directly Linked Particles Must Not Collide

Two particles joined by a short distance link are intentionally close. Their constraint says:

```text
stay approximately `distance` apart
```

Their colliders might say:

```text
stay at least `radius_a + radius_b` apart
```

If those requirements conflict, the attachment solver pulls the particles together while self-collision pushes them apart. The result is jitter, extra energy, and a chain that looks rigid or explosive.

Example:

```text
particle radii: 8 and 8
collision distance: 16
link distance: 10
```

No configuration can satisfy both constraints. The solver fights forever.

Therefore the default rule is:

> A directly linked particle pair does not self-collide.

This rule is generic. It applies to a rope link, jelly spoke, eel segment, caterpillar side appendage, or any future graph edge.

## General Direct-Link Test

Do not identify neighbors with `EelPart`, indices, or a creature-specific component. Ask the existing constraint graph whether either entity directly attaches to the other.

```zig
fn areDirectlyLinked(world: *ecs.world_t, first: ecs.entity_t, second: ecs.entity_t) bool {
    const first_target = ecs.get_target(world, first, ecs.id(components.AttachedTo), 0);
    const second_target = ecs.get_target(world, second, ecs.id(components.AttachedTo), 0);

    return first_target == second or second_target == first;
}
```

In `verlet_self_collision_system`, skip the pair after the duplicate/self test:

```zig
if (e1 >= e2) continue;
if (areDirectlyLinked(world, e1, e2)) continue;
```

This works because the current `AttachedTo` representation permits one parent per particle. If the engine later permits multiple `AttachedTo` targets, replace the single-target lookup with a relation-pair search that checks all direct links for each entity.

## Why Existing Parent Equality Is Not Enough

The current code skips collisions when two particles share the same direct `AttachedTo` target:

```zig
if (parent1 != 0 and parent1 == parent2) continue;
```

This is not a correct general self-collision rule:

- Two siblings attached to the same jelly center may still need collision.
- A parent and its direct child do not share the same parent, so they still collide and fight their link.
- A chain has no siblings, so this does nothing useful for adjacent eel links.

Replace the condition with `areDirectlyLinked`. Whether siblings should collide is an authored creature decision; the default should be yes because it prevents structural collapse.

## Optional Collision Groups

Some structures need deliberate self-collision exclusions beyond direct links. For example, a jelly center might be allowed to overlap its skin, or an accessory cloud may overlap its owner.

Add generic configuration only when a real creature needs it:

```zig
pub const VerletCollisionGroup = struct {
    group: u16,
    mask: u16,
};
```

Two particles collide only when both masks include the other particle's group. This is the same concept as layer/mask filtering in conventional collision systems.

Avoid adding it before there is a concrete need. Direct-link exclusion is the essential first rule.

## Excluding Near Neighbors Beyond One Link

For a dense chain, particle $i$ and particle $i+2$ can collide even though they are almost structurally adjacent. Sometimes that is desirable because it stops extreme folding. Sometimes it creates jitter around sharp bends.

Start with direct links only. If a specific creature jitters, extend the definition with an explicit self-collision exclusion list:

```zig
const CreatureCollisionExclusion = struct {
    first_index: usize,
    second_index: usize,
};
```

The generic spawner can translate that list into a generic relation/tag-based exclusion lookup. Do not infer "two hops apart" globally: rings, branches, and side appendages make graph distance semantically different for each creature.

## Verlet Velocity Side Effect

In Verlet, velocity is derived from the difference between current and old position. If self-collision changes `Position` but not `old_position`, it adds outward velocity for the next integration step.

This can make contacts lively, but too much correction creates unstable energy.

Use a deliberate policy:

- For bouncy/squishy creatures, correct only current position or preserve a small fraction of the correction in old position.
- For calm/rope-like creatures, apply the same correction to current and old position, preserving velocity.
- For a mixed feel, preserve a configurable fraction of velocity.

Do not leave this as an accidental implementation detail. Once the generic spawner exists, add a shared contact policy only if different creature definitions need materially different behavior.

## Solver Order

The current solver resolves attachments, then terrain and self-collision. This is sufficient for early experiments but means the final contact correction can stretch distance links.

The stable target loop is:

```text
predict Verlet positions
repeat solver iterations:
  solve all distance links
  solve terrain contacts
  solve self-collision contacts
  solve explicit player-to-creature contacts
```

All of these are positional constraints. Running them in the same iteration loop means a terrain or self-collision correction is repaired by the links during that same fixed simulation step.

## Scaling Warning

Checking every Verlet particle against every other particle is $O(V^2)$. This is fine for a handful of prototype creatures but will grow quickly with long caterpillars and multiple creatures.

After the behavior is correct, use a uniform spatial hash:

1. Insert each Verlet collider into the buckets overlapped by its AABB.
2. Compare only entities in the same or neighboring buckets.
3. Retain duplicate-pair prevention and `areDirectlyLinked` filtering.

The collision policy stays identical; only the candidate search becomes local.

# Implementation Order

1. Add `CreatureNode`, `CreatureLink`, `CreatureDrive`, and `CreatureDefinition` near the existing creature spawn code.
2. Create `spawnCreature` using existing generic particle components.
3. Spawn a small eel definition; do not add new physics systems.
4. Add generic direct-link exclusion to self-collision.
5. Verify an eel stays connected, does not explode, and cannot fold through distant body sections.
6. Convert the jelly spawn to use the same definition/spawner when its current behavior is stable.
7. Create a caterpillar by authoring auxiliary node/link data.
8. Only then consider creature-specific high-level behaviors such as targeting, gait, attacks, health, or special contact policies.

## Success Criteria

A successful arbitrary-creature system has these properties:

- A new chain, ring, or branching creature can be authored without a new physics system.
- Every particle uses the same Verlet and terrain collision code.
- Directly linked particles do not self-collide.
- Distant parts of the same creature do self-collide by default.
- A caterpillar is expressed as additional nodes/links, not as a new physics category.
- Creature-specific behavior is an optional layer above generic simulation.