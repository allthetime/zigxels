# ECS Options: `zflecs`, Zig Ecosystem, and Rolling Our Own

## Context: What This Project Actually Uses ECS For

Before comparing libraries or designing a replacement, look at what `pixels` currently stores in Flecs:

| Domain | Approximate Count | Shape / Needs |
| --- | --- | --- |
| `Player` & `Gun` | 1–2 | Singletons with custom kinematic/recoil logic |
| `Bullet` | 0–200 | Homogeneous (`pos`, `vel`, `radius`, `physics`, `color`), bulk cleanup on reset |
| `ExplosionParticle` | 0–500 | Short-lived homogeneous debris with lifetime + color |
| `EffectZone` | 1–20 | Static/moving bounding boxes stamping GPU shader flags |
| Verlet nodes (`VerletState`) | 10–300 | Particles + `AttachedTo` / `ReachTowards` constraint graphs + PBD relaxation |
| `GroundGrid` tiles | 100s–1000s | **Should leave ECS** for a chunked `MaterialGrid` regardless of ECS choice |

Once terrain moves out of ECS into a material grid, this game does not have tens of thousands of arbitrary dynamic component permutations—it has **hundreds of entities across ~5 well-known archetypes**, plus a **Verlet constraint graph**.

---

## Option 1: Keep `zflecs` (Current Choice)

`zig-gamedev/zflecs` wraps Flecs v4 (C99) with Zig build integration and bindings.

### Where It Helps This Project
- **Hierarchies (`ChildOf`):** Deleting a group entity (`BulletsGroup`, `CreatureGroup`, `GroundGroup`) cascades cleanly on world reset.
- **Relationships / Pairs:** `AttachedTo` and `ReachTowards` model particle constraints without manual graph arrays during early prototyping.
- **Flecs Explorer (`localhost:2771`):** Live inspection of entities, components, and system timing with zero custom UI code.
- **Actively updated for Zig:** `zig-gamedev/zflecs` tracks Zig releases (including Zig `0.17.0` + Flecs `4.1.5`).

### Where It Creates Friction Here
- **C-style API ergonomics:** Raw `*ecs.world_t`, positional `ecs.field(it, T, index)` lookups, mandatory `ecs.iter_fini` on early loop exits, and C callbacks.
- **PBD solver batching:** Flecs groups `AttachedTo` iteration by resolved target archetype, which runs relaxation per-target batch instead of in one deterministic global Gauss-Seidel loop across all constraints.
- **Build-flag footgun:** Failing to forward `.target` and `.optimize` into `b.dependency("zflecs", ...)` silently compiles Flecs in `Debug` + `sanitize` mode even on release builds.

---

## Option 2: Other ECS Libraries in the Zig Ecosystem

Pre-1.0 Zig moves quickly (`std.Io`, `build.zig`, and `std.process.Init` changes across `0.15 → 0.17`), so ecosystem churn is a real factor—several notable Zig ECS projects (such as `ecez` and `zevy-ecs`) have been archived.

The main pure-Zig options worth knowing about:

### 1. `Games-by-Mason/ZCS` (Archetype-based)
- **Style:** Archetype storage built for a real indie game (*Way of Rhea*).
- **Features:** Generational entity keys, command buffers, optional thread-pool support, Tracy hooks.
- **Tradeoff vs. `zflecs`:** Idiomatic pure Zig with no C compilation, but no Flecs-style relationship pairs or built-in web Explorer UI. Check current `0.17` compatibility before adopting.

### 2. `prime31/zig-ecs` (Sparse-set, EnTT-style)
- **Style:** Port/adaptation of C++ EnTT using Zig `comptime` generics (`View` and owning `Group`).
- **Features:** Lightweight, familiar C++/EnTT API, zero C dependency.
- **Tradeoff vs. `zflecs`:** Sparse sets are ergonomic for simple component mixes, but you lose relationship pairs, cascade hierarchies, and the Explorer UI; verify Zig `0.17` maintenance status before relying on it.

### 3. `freakmangd/zentig_ecs` / `linuxy/coyote-ecs`
- Lighter/Bevy-inspired pure-Zig ECS libraries. Useful for inspiration, though smaller maintainer footprints mean higher risk of lagging behind Zig toolchain upgrades.

### Ecosystem Verdict
If you want a **general-purpose ECS**, none of the pure-Zig libraries clearly beat `zflecs` on features or stability right now—swapping `zflecs` for another third-party generic ECS mostly trades C ergonomics for Zig-version maintenance risk while losing `ChildOf` cascades, pair relations, and Flecs Explorer.

---

## Option 3: Rolling Our Own System (Recommended Path *If* We Leave Flecs)

If you eventually want 100% pure Zig with zero C/ECS ceremony, **do not build a generic runtime archetype ECS**. Building an archetype engine (type-erased tables, bitsets, query caches, deferred command buffers) is engine infrastructure you do not need when all entity kinds are known at compile time.

Instead, use **typed domain containers + generational handles + an explicit frame pipeline**.

### 1. Core Building Block: `SlotMap(T)` (or `MultiArrayList` + Free List)

For anything that needs stable cross-references (e.g., constraints pointing to particles, creatures referencing nodes), use a tiny generational handle pool:

```zig
pub fn Handle(comptime T: type) type {
    _ = T;
    return packed struct(u64) {
        index: u32,
        gen: u32,
    };
}

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Entry = struct {
            gen: u32 = 1,
            alive: bool = false,
            value: T = undefined,
        };

        entries: std.ArrayListUnmanaged(Entry) = .empty,
        free_indices: std.ArrayListUnmanaged(u32) = .empty,

        // spawn -> Handle(T), get(h) -> ?*T, despawn(h), reset()
    };
}
```

For homogeneous fire-and-forget things (`Bullet`, `ExplosionParticle`) that nothing points to, you don't even need handles—a plain `std.MultiArrayList(Bullet)` with `swapRemove` gives you ECS-grade SoA cache locality with normal Zig slices (`bullets.items(.pos)`, `bullets.items(.vel)`).

### 2. Domain-Owned `GameWorld` Instead of Generic Entities

Each simulation model already identified in `HYBRID_ENGINE_ARCHITECTURE.md` gets its own explicit storage inside one `GameWorld` struct:

```zig
pub const GameWorld = struct {
    player: Player,
    gun: Gun,
    bullets: std.MultiArrayList(Bullet),
    particles: std.MultiArrayList(ExplosionParticle),
    verlet: VerletWorld,
    effect_zones: std.ArrayListUnmanaged(EffectZone),
    // terrain lives in MaterialGrid, not entities

    pub fn step(self: *GameWorld, input: InputSnapshot, dt: f32) void {
        self.gun.updateAim(&self.player, input.aim);
        self.gun.tryShoot(&self.player, input, &self.bullets, dt);
        self.player.step(input, &self.verlet, dt);
        self.stepBullets(dt);
        self.verlet.step(&self.player, dt); // single deterministic PBD loop
        self.stepParticles(dt);
    }

    pub fn reset(self: *GameWorld) void {
        self.bullets.len = 0;
        self.particles.len = 0;
        self.verlet.clear();
        self.player.reset();
        // respawn level + creatures cleanly in 5 lines
    }
};
```

### 3. Why `VerletWorld` Is Specifically Better Out of ECS

In Verlet/PBD, particles and constraints want two flat arrays:

```zig
pub const VerletWorld = struct {
    particles: std.MultiArrayList(VerletParticle), // pos, old_pos, radius, inv_mass, damping, group_id
    links: std.ArrayListUnmanaged(DistanceLink),   // a: u32, b: u32, rest_dist: f32, stiffness: f32
    drives: std.ArrayListUnmanaged(TargetDrive),   // particle: u32, target: DriveTarget, stiffness: f32
};
```

Benefits over Flecs `(AttachedTo, target)` pairs:
- **Deterministic Gauss-Seidel PBD loop:** Predict particles → run `N` iterations of `(links + terrain + player contacts + self-collision)` in exact order → never affected by Flecs table ordering.
- **No accidental `Velocity` component** on Verlet particles.
- **Trivial direct-link exclusion for self-collision:** Each link `(a, b)` or creature `group_id` is right there in plain structs—no `ecs.get_target(..., 0)` hacks.

### 4. Tradeoffs of Rolling Our Own

| Aspect | `zflecs` | Typed Pools (`GameWorld`) |
| --- | --- | --- |
| Build & Toolchain | C99 compile + Zig bindings | 100% pure Zig, compiles instantaneously |
| Execution Order | Implicit pipeline + manual `ecs.query_iter` | Plain Zig calls in `step(dt)` and `render()` |
| Safety | Runtime `ecs.field` index + `iter_fini` rules | Compile-time checked slices & structs |
| Reset Lifecycle | Needs careful `ChildOf` group hygiene | `.clearRetainingCapacity()` per container |
| Tooling | Flecs Explorer web UI out of the box | Must build our own debug overlay / counters |
| Prototyping Ad-Hoc Tags | Fast (attach any tag to any entity) | Requires adding a field or array to a domain |

---

## Recommendation for `pixels`

1. **Right now (Zig `0.17.1` + SDL3 upgrade):** Stay on updated `zflecs`. Don't rewrite the ECS layer while changing the Zig compiler and window/input backend at the same time.
2. **During gameplay cleanup:** Keep adding `CreatureGroup` / proper ownership groups in Flecs, and move terrain out of ECS into a `MaterialGrid` (no ECS library handles cellular sand/water well).
3. **First candidate to extract if/when Flecs annoys you:** Move **only `VerletWorld`** (particles + distance links + PBD solver) into a self-contained Zig struct wrapped by a single Flecs singleton or creature entity, rather than doing a big-bang rewrite. If that feels noticeably cleaner and faster to work in, `Bullets` and `Particles` are trivial to migrate afterward.
