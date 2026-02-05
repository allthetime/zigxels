# Physics System Architecture

This document outlines the architecture for integrating a Physics World concept into the `@pixels` ECS-based engine using the `cute_c2` collision library.

## Core Concepts

It is important to distinguish between the two layers of physics:

1.  **Collision Library (`pure_zig_c2`)**: A stateless calculator. You give it shapes and positions, and it returns "Yes/No" or "Penetration Depth". It does not know about velocity, mass, or time.
2.  **Physics World (Engine)**: The stateful manager. It handles the simulation loop: `Integrate -> Detect -> Resolve`.

## ECS Integration Strategy

Since we are using `zflecs` (ECS), we avoid creating a separate "World" object that duplicates entity data. Instead, the **ECS is the World**.

### 1. Components

We define components to represent physical properties.

```zig
const c2 = @import("cute_c2");

// Defines the shape for collision detection
pub const Collider = struct {
    shape: c2.Shape,          // Circle, AABB, Capsule, or Poly
    offset: c2.Vec2,          // Local offset from entity Position
    is_trigger: bool = false, // If true, detects collision but doesn't push back
};

// Defines properties for physical resolution (The "Physics" part)
pub const RigidBody = struct {
    mass: f32,
    inv_mass: f32,       // 1.0 / mass (0.0 for static bodies)
    restitution: f32,    // Bounciness (0.0 = rock, 1.0 = superball)
    force: c2.Vec2,      // Accumulated forces for this frame
    velocity: c2.Vec2,   // Linear velocity
};

// Tag for Kinematic Controllers (Platformer characters)
// These ignore standard RigidBody resolution and are moved manually by code.
pub const KinematicCharacter = struct { _dummy: u8 };
```

### 2. Hybrid Physics Architecture

The game requires two distinct types of movement that can coexist.

#### Type A: Rigid Body Physics (Dynamic)
*   **Use Case:** Bouncing crates, grenades, debris, falling rocks.
*   **Behavior:** Controlled by forces (Gravity, Explosions). Bounces off walls.
*   **System:** `RigidBodySystem`.

#### Type B: Kinematic Physics (Controller)
*   **Use Case:** Player Character, Moving Platforms.
*   **Behavior:** Controlled by Input and Logic (e.g., "Move Right", "Jump"). Snaps to ground, handles slopes, does not "bounce".
*   **System:** `PlatformerMoveSystem` (Existing `move_x`/`move_y` logic).

---

## Implementation Reference

### Rigid Body System (The "World" Logic)

This system replaces the concept of an external `PhysicsWorld` class. It runs every frame.

```zig
fn rigid_body_system(it: *ecs.iter_t) callconv(.c) void {
    const positions = ecs.field(it, Position, 1).?;
    const bodies = ecs.field(it, RigidBody, 2).?;
    
    const dt = it.delta_time;
    const gravity = c2.Vec2.init(0, 9.8);

    // 1. Integration Step
    for (0..it.count) |i| {
        if (bodies[i].inv_mass == 0) continue; // Static

        // Symplectic Euler Integration
        // v += (g + F/m) * dt
        const accel = gravity.add(bodies[i].force.mul(bodies[i].inv_mass));
        bodies[i].velocity = bodies[i].velocity.add(accel.mul(dt));

        // x += v * dt
        positions[i].x += bodies[i].velocity.x * dt;
        positions[i].y += bodies[i].velocity.y * dt;

        // Reset force
        bodies[i].force = c2.Vec2.init(0, 0);
    }

    // 2. Collision Resolution Step
    // (Simplified N^2 loop for demonstration. Real implementation needs Broadphase)
    solve_collisions(it);
}

fn solve_collisions(it: *ecs.iter_t) void {
    // Iterate all pairs, generate Manifold with c2.collide()
    // Apply Impulse Resolution:
    // j = -(1 + e) * v_rel . n / (inv_mass_a + inv_mass_b)
}
```

### Kinematic System (Platformer Logic)

This system keeps full control over the movement but uses `c2` for environment checking.

```zig
fn platformer_system(it: *ecs.iter_t) callconv(.c) void {
    // 1. Calculate desired velocity based on Input
    // 2. Move X axis
    // 3. Check for Collider overlaps (using c2.collided or c2.castRay)
    // 4. If hit, snap back to surface (separation)
    // 5. Repeat for Y axis
}
```

## Integrating Both

To have both systems interact (e.g., Player pushes a Box):

1.  **Layers/Masks:** Define what collides with what.
2.  **One-Way Coupling:**
    *   The **RigidBodySystem** treats the Player (Kinematic) as a Static Object with infinite mass (`inv_mass = 0`).
    *   When the Player moves, it effectively "teleports" or sweeps. If it hits a RigidBody, the RigidBody is pushed out by the resolution solver in the next frame.
    *   Alternatively, the Player can apply an explicit `Force` to the RigidBody upon contact.

## Workflow for Adding New Objects

1.  **Static Geometry (Ground):**
    *   Add `Position`, `Collider` (Box/Poly).
    *   Do NOT add `RigidBody` (or add with `inv_mass = 0`).

2.  **Dynamic Objects (Grenade):**
    *   Add `Position`, `Collider` (Circle).
    *   Add `RigidBody` (Mass = 1, Restitution = 0.8).

3.  **Player:**
    *   Add `Position`, `Collider` (Capsule/Box).
    *   Add `KinematicCharacter` tag.
    *   Add `Velocity` (for logic use, not physics integration).
