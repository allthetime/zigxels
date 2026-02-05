# Leveraging Flecs Pairs (Relationships)

Flecs differs from traditional ECS implementations by treating entities as nodes in a graph rather than just rows in a database. This is achieved through **Pairs** (also called Relationships).

A Pair allows you to attach a Component to an Entity *in relation to* something else.
Format: `(Relationship, Target)`

## 1. Hierarchy (Parent / Child)

This is the most common usage, allowing for scene graphs and automatic cleanup.

```zig
// Usage: "Bullet is a Child Of Group"
ecs.add_pair(world, bullet, ecs.ChildOf, bullets_group);
```

### Benefits
*   **Automatic Lifecycle:** If you `ecs.delete(world, bullets_group)`, Flecs automatically deletes all entities that have a `(ChildOf, bullets_group)` pair.
*   **Cascading Transforms:** You can write a system that queries `(Position, ecs.ChildOf, Parent)`. By reading the Parent's position inside the system, you can calculate the Child's world position relative to the parent without a complex separate scene tree.

## 2. Inventory & Slots (Equipment)

Instead of complex `InventoryComponent` arrays, use pairs to link items to specific slots on a character.

```zig
// Define Tags
const EquippedTo = ecs.new_entity(world, "EquippedTo");
const MainHand = ecs.new_entity(world, "MainHand");
const OffHand = ecs.new_entity(world, "OffHand");

// Usage
ecs.add_pair(world, sword_entity, EquippedTo, MainHand);
ecs.add_pair(world, shield_entity, EquippedTo, OffHand);
```

### Benefits
*   **Specific Queries:** You can write a system that only draws items currently in hands.
    *   Query: `(Position, Sprite, (EquippedTo, MainHand))`
*   **Easy Swapping:** To unequip, just `ecs.remove_pair(world, sword, EquippedTo, MainHand)`.

## 3. Finite State Machines (FSM)

Pairs can act as a high-performance, clean State Machine using the `ecs.Switch` property.

```zig
// Setup: Define "State" as a generic container for exclusive states
const State = ecs.new_entity(world, "State");
ecs.add_id(world, State, ecs.Switch); // Enforces exclusivity

const Idle = ecs.new_entity(world, "Idle");
const Jumping = ecs.new_entity(world, "Jumping");

// Usage
ecs.add_pair(world, player, State, Idle);

// Transition
ecs.add_pair(world, player, State, Jumping); 
// RESULT: Flecs automatically REMOVES (State, Idle) because of ecs.Switch!
```


Sytem that only applies to a certain state.

```zig
_ = ecs.ADD_SYSTEM(world, "JumpLogic", ecs.OnUpdate, jump_system, &.{
    .{ .id = ecs.pair(State, Jumping) } 
});
```

### Benefits
*   **Clean Systems:** You don't need `if (state == Jumping)` inside your update loop. You simply register a system that *only* matches entities with the `(State, Jumping)` pair.
*   **Safety:** You cannot accidentally be in two states at once.

## 4. Logical Interaction & AI

Use pairs to define abstract game rules and AI targets.

```zig
// AI Targeting
ecs.add_pair(world, enemy_unit, Targeting, player_entity);

// Faction logic
ecs.add_pair(world, player_entity, Faction, Allied);
ecs.add_pair(world, enemy_unit, Faction, Axis);
```

### Benefits
*   **Graph Queries:** You can query "Get me all units Targeting the Player".
*   **Material Systems:** Define physics friction using pairs like `(Friction, Ice)` or `(Friction, Sand)` to override default rigid body behavior without creating unique component types for every surface.
