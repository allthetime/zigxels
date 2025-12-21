# Pixels ECS Engine

A Zig-based game engine separating the "How" (Engine) from the "What" (Game) using an Entity Component System (ECS).

## Architecture

### 1. Directory Structure
*   **`src/engine/`**: Core infrastructure.
    *   `core.zig`: The `Engine` struct. Owns memory (GPA/Arena), SDL Window/Renderer, and the Pixel Buffer.
    *   `input.zig`: `InputState` struct. Captures mouse/keyboard state once per frame.
*   **`src/game/`**: Gameplay logic.
    *   `components.zig`: Pure data structs (`Position`, `Velocity`, `Rectangle`).
    *   `systems.zig`: Logic functions (`move_system`, `render_system`).
*   **`src/main.zig`**: The glue. Initializes the Engine, registers ECS systems, and runs the main loop.

### 2. The "Context" Pattern
We avoid global variables by passing the `*Engine` pointer into the ECS world context.

*   **Setup** (`main.zig`):
    ```zig
    // Pass the engine pointer to the ECS world so systems can access it
    // Note: 'engine' is stack-allocated in main, so we pass its address
    ecs.set_ctx(world, &engine, dummy_free);
    ```
*   **Usage** (`systems.zig`):
    Systems retrieve the engine using a helper function to access the Renderer or Pixel Buffer.
    ```zig
    const engine = Engine.getEngine(it.world);
    engine.renderer.fillRect(...);
    ```

### 3. Memory Management
*   **Engine**: Owns the `GeneralPurposeAllocator` and `ArenaAllocator`.
*   **Arena**: Reset every frame in `engine.beginFrame()` for temporary allocations.
*   **Cleanup**: `engine.deinit()` handles orderly destruction of SDL resources and memory.

## Dependencies
*   **SDL2**: Windowing and Rendering.
*   **zflecs**: Zig bindings for the Flecs ECS.

## Running
```bash
zig build run
```

