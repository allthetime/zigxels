# Verlet Integration & Inverse Kinematics System Foundation

## 1. Core Concept

**Verlet Integration** is a method of calculating physics where we do not explicitly store or integrate "Velocity". Instead, momentum and velocity are derived implicitly from the difference between the **Current Position** and the **Previous Position**.

*   **Euler (Standard)**: `NewPos = Pos + Velocity * dt`
*   **Verlet**: `Velocity ≈ (Pos - OldPos)`. Therefore: `NewPos = Pos + (Pos - OldPos) + Acceleration * dt²`

### Why use it?
It enables **Position Based Dynamics (PBD)**. This is particularly powerful for Inverse Kinematics (IK), cloth, and ropes. To satisfy constraints (like keeping two points at a fixed distance), you simply modify their positions directly. The physics engine automatically interprets this position change as velocity/momentum for the next frame, creating stable, physical behavior without complex differential equations.

## 2. Architecture Integration

To integrate Verlet physics alongside an existing Euler/Velocity-based engine (like `zflecs` + standard physics), we treat Verlet entities as a distinct physics layer.

### Integration Strategy

1.  **Strict Separation**: Entities are either controlled by standard physics (Euler) OR Verlet physics, never both simultaneously for movement integration.
2.  **Verlet Components**: We introduce specific components (`VerletState`) that act as the "physics engine" for these specific entities.
3.  **Hybrid Interaction**:
    *   **Standard -> Verlet**: Standard entities can act as "Anchors" (infinite mass) for Verlet chains.
    *   **Verlet -> Standard**: Verlet entities can have Colliders, allowing standard entities to collide with them.

## 3. Data Structures

Three core components define the system foundation.

### A. The Verlet State
Stores the simulation data required for the integration step.
```zig
pub const VerletState = struct {
    old_x: f32,
    old_y: f32,
    mass: f32 = 1.0,      // 0.0 represents infinite mass (Pinned/Anchor)
    friction: f32 = 0.95, // 1.0 = vacuum, 0.9 = air resistance
};
```

### B. The Constraint
Defines a rule that must be satisfied between two entities (e.g., a "Bone" or "Rope Segment").
```zig
pub const DistanceConstraint = struct {
    target: ecs.entity_t, // The entity this constraint attaches to
    dist: f32,            // Desired distance
    stiffness: f32 = 1.0, // 1.0 = Rigid, <1.0 = Elastic/Springy
};
```

### C. The Tags
Used to organize the entities within the ECS pipeline.
```zig
pub const VerletEntity = struct {}; // Tag for easy filtering
```

## 4. The System Pipeline

The order of execution is critical for stability. The Verlet pipeline typically runs **before** collision resolution but **after** standard input/gameplay logic.

### Phase 1: Integration (The "Move" Step)
Iterate all entities with `VerletState`.
1.  **Calculate Velocity**: `vx = (pos.x - old_pos.x) * friction`
2.  **Integrate**: `new_pos.x = pos.x + vx + (accel.x * dt * dt)`
3.  **Update History**: `old_pos = pos`, `pos = new_pos`

### Phase 2: Constraint Solving (The "Fix" Step)
Iterate all entities with `DistanceConstraint`. This step resolves the physical rules.
*   **Sub-stepping**: This loop should run multiple times (e.g., 4-8 iterations) per frame to stiffen the constraints.
1.  **Measure**: Calculate current distance between Entity A and Target B.
2.  **Compare**: `diff = (current_dist - target_dist) / current_dist`.
3.  **Resolve**: Move A and B towards/away from each other based on `diff`.
    *   **Weighting**: Movement is weighted by inverse mass.
    *   If `mass=0` (Pinned), that entity does not move; the other entity takes 100% of the correction.

### Phase 3: Collision Handling (Optional)
If Verlet entities need to collide with the world:
1.  Check for intersection (e.g., AABB vs Point).
2.  If colliding, push `pos` out of the collider.
3.  *Note*: No velocity update is needed. The change in `pos` will automatically result in a bounce next frame due to the Verlet integration formula.

## 5. Implementation Roadmap

When implementing this system from scratch:

1.  **Component Registration**: Register `VerletState` and `DistanceConstraint`.
2.  **Integrator System**: Implement the basic `pos += (pos - old_pos)` logic. Verify that points maintain momentum.
3.  **Constraint Solver**: Implement the distance resolution logic.
    *   Start with 1 iteration.
    *   Ensure infinite mass (0.0) is respected (Anchors don't move).
4.  **Chain Construction**: Create a helper to spawn multiple entities linked by constraints.
5.  **Render System**: Create a debug system to draw lines representing the `DistanceConstraint` connections.