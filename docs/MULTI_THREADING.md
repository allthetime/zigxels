# Multithreading Strategies

This document outlines multithreading approaches for the Zigxels game engine, covering ECS parallelism, pixel buffer operations, and job queue systems.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Main Thread                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Input     │  │   ECS       │  │   Render (present)      │  │
│  │   Polling   │  │   Update    │  │                         │  │
│  └─────────────┘  └──────┬──────┘  └─────────────────────────┘  │
│                          │                                       │
└──────────────────────────┼───────────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │  Worker 1  │  │  Worker 2  │  │  Worker N  │
    │            │  │            │  │            │
    │ - Physics  │  │ - Pixels   │  │ - Pixels   │
    │ - Collision│  │   (rows    │  │   (rows    │
    │            │  │   0-239)   │  │   240-479) │
    └────────────┘  └────────────┘  └────────────┘
```

## Parallelization Opportunities

| System | Parallelizable? | Approach | Speedup Potential |
|--------|-----------------|----------|-------------------|
| `gravity_system` | Yes | Flecs threading | Low (simple math) |
| `move_x_system` / `move_y_system` | Yes | Flecs threading | Low |
| `collision_axis` | Yes | Spatial partitioning + threads | High |
| `render_pixel_box` / pixel buffer | Yes | Split by rows | High |
| `player_input_system` | No | Single entity, needs atomicity | N/A |
| Background gradient | Yes | Split by rows | High |

---

## Option 1: Flecs Built-in Threading

zflecs (Flecs) has native multithreading support. Systems that access different components can run in parallel automatically.

### Enabling Flecs Threading

```zig
// In main.zig, after world creation
const world = ecs.init();

// Enable threading with N worker threads
ecs.set_threads(world, 4);
```

### How It Works

Flecs analyzes component access patterns:
- Systems reading/writing **different** components → run in parallel
- Systems accessing **same** components → run sequentially

```zig
// These could run in parallel (different components):
// - gravity_system: writes Velocity
// - player_clamp_system: writes Position

// These must be sequential (same components):
// - move_x_system: reads Velocity, writes Position
// - move_y_system: reads Velocity, writes Position
```

### Pipeline Phases

For explicit ordering, use Flecs phases:

```zig
// Define phases
const PreUpdate = ecs.new_id(world);
const Update = ecs.new_id(world);
const PostUpdate = ecs.new_id(world);

// Assign systems to phases
ecs.system(world, "gravity", .{ .phase = PreUpdate }, gravity_system);
ecs.system(world, "move_x", .{ .phase = Update }, move_x_system);
ecs.system(world, "collision", .{ .phase = PostUpdate }, ground_collision_x_system);
```

---

## Option 2: Parallel Pixel Buffer Operations

The pixel buffer operations in `pixels.zig` are ideal for parallelization—each pixel is independent.

### Row-Based Parallelism

Split the screen into horizontal strips, one per thread:

```zig
const std = @import("std");

pub fn drawBackgroundParallel(
    buffer: []u32,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,
) void {
    const num_threads: usize = std.Thread.getCpuCount() catch 4;
    const rows_per_thread = height / num_threads;
    
    var threads = allocator.alloc(std.Thread, num_threads) catch return;
    defer allocator.free(threads);
    
    for (0..num_threads) |i| {
        const start_row = i * rows_per_thread;
        const end_row = if (i == num_threads - 1) height else (i + 1) * rows_per_thread;
        
        threads[i] = std.Thread.spawn(.{}, drawRowRange, .{
            buffer,
            width,
            start_row,
            end_row,
        }) catch continue;
    }
    
    // Wait for all threads to complete
    for (threads) |t| {
        t.join();
    }
}

fn drawRowRange(buffer: []u32, width: u32, start_row: usize, end_row: usize) void {
    for (start_row..end_row) |y| {
        const row_start = y * width;
        for (0..width) |x| {
            // Your gradient/pixel logic here
            const color = computePixelColor(x, y);
            buffer[row_start + x] = color;
        }
    }
}
```

### Thread Pool for Reuse

Spawning threads every frame is expensive. Use a persistent thread pool:

```zig
pub const ThreadPool = struct {
    workers: []std.Thread,
    work_queue: std.ArrayList(WorkItem),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    
    pub const WorkItem = struct {
        func: *const fn (*anyopaque) void,
        data: *anyopaque,
    };
    
    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !ThreadPool {
        var pool = ThreadPool{
            .workers = try allocator.alloc(std.Thread, num_workers),
            .work_queue = std.ArrayList(WorkItem).init(allocator),
        };
        
        for (pool.workers) |*w| {
            w.* = try std.Thread.spawn(.{}, workerLoop, .{&pool});
        }
        
        return pool;
    }
    
    pub fn submit(self: *ThreadPool, work: WorkItem) void {
        self.mutex.lock();
        self.work_queue.append(work) catch {};
        self.mutex.unlock();
        self.condition.signal();
    }
    
    fn workerLoop(pool: *ThreadPool) void {
        while (!pool.shutdown.load(.acquire)) {
            pool.mutex.lock();
            
            while (pool.work_queue.items.len == 0 and !pool.shutdown.load(.acquire)) {
                pool.condition.wait(&pool.mutex);
            }
            
            if (pool.shutdown.load(.acquire)) {
                pool.mutex.unlock();
                break;
            }
            
            const work = pool.work_queue.orderedRemove(0);
            pool.mutex.unlock();
            
            work.func(work.data);
        }
    }
    
    pub fn deinit(self: *ThreadPool, allocator: std.mem.Allocator) void {
        self.shutdown.store(true, .release);
        self.condition.broadcast();
        
        for (self.workers) |w| {
            w.join();
        }
        
        allocator.free(self.workers);
        self.work_queue.deinit();
    }
};
```

---

## Option 3: Parallel Collision Detection

The `collision_axis` function is O(n×m) where n = moving entities, m = ground entities. This can be parallelized with care.

### Spatial Partitioning

First, reduce the problem with spatial hashing:

```zig
pub const SpatialHash = struct {
    cell_size: f32,
    cells: std.AutoHashMap(CellKey, std.ArrayList(EntityId)),
    
    pub const CellKey = struct { x: i32, y: i32 };
    
    pub fn insert(self: *SpatialHash, entity: EntityId, pos: Position, size: f32) void {
        const min_cell = self.posToCell(pos.x - size, pos.y - size);
        const max_cell = self.posToCell(pos.x + size, pos.y + size);
        
        var cy = min_cell.y;
        while (cy <= max_cell.y) : (cy += 1) {
            var cx = min_cell.x;
            while (cx <= max_cell.x) : (cx += 1) {
                const key = CellKey{ .x = cx, .y = cy };
                var list = self.cells.getOrPut(key) catch continue;
                if (!list.found_existing) {
                    list.value_ptr.* = std.ArrayList(EntityId).init(self.allocator);
                }
                list.value_ptr.append(entity) catch {};
            }
        }
    }
    
    pub fn query(self: *SpatialHash, pos: Position, size: f32) []EntityId {
        // Return entities in nearby cells only
    }
    
    fn posToCell(self: *SpatialHash, x: f32, y: f32) CellKey {
        return .{
            .x = @intFromFloat(@floor(x / self.cell_size)),
            .y = @intFromFloat(@floor(y / self.cell_size)),
        };
    }
};
```

### Parallel Collision Checks

With spatial partitioning, each entity only checks nearby entities:

```zig
fn collision_parallel(positions: []Position, boxes: []Box, velocities: []Velocity, spatial_hash: *SpatialHash) void {
    const num_threads = std.Thread.getCpuCount() catch 4;
    const chunk_size = positions.len / num_threads;
    
    var threads: [16]std.Thread = undefined;
    
    for (0..num_threads) |i| {
        const start = i * chunk_size;
        const end = if (i == num_threads - 1) positions.len else (i + 1) * chunk_size;
        
        threads[i] = std.Thread.spawn(.{}, collisionChunk, .{
            positions[start..end],
            boxes[start..end],
            velocities[start..end],
            spatial_hash,
        }) catch continue;
    }
    
    for (threads[0..num_threads]) |t| t.join();
}

fn collisionChunk(
    positions: []Position,
    boxes: []Box,
    velocities: []Velocity,
    spatial_hash: *SpatialHash,
) void {
    for (positions, boxes, velocities) |*pos, box, *vel| {
        // Only check nearby entities from spatial hash
        const nearby = spatial_hash.query(pos.*, @floatFromInt(box.size));
        
        for (nearby) |other_id| {
            // Check collision with other_id
            // Update pos and vel if colliding
        }
    }
}
```

---

## Option 4: Full Job Queue System

A job queue provides maximum flexibility for dynamic workloads.

### When to Use

- Tasks spawn subtasks (e.g., quadtree traversal)
- Highly variable frame-to-frame workload
- Need fine-grained task dependencies

### Implementation

```zig
pub const JobSystem = struct {
    pool: ThreadPool,
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    pub const Job = struct {
        func: *const fn (ctx: *anyopaque, job_system: *JobSystem) void,
        ctx: *anyopaque,
    };
    
    pub fn schedule(self: *JobSystem, job: Job) void {
        _ = self.pending.fetchAdd(1, .monotonic);
        self.pool.submit(.{
            .func = runJob,
            .data = @ptrCast(&.{ .job = job, .system = self }),
        });
    }
    
    fn runJob(data: *anyopaque) void {
        const ctx: *struct { job: Job, system: *JobSystem } = @ptrCast(@alignCast(data));
        ctx.job.func(ctx.job.ctx, ctx.system);
        _ = ctx.system.pending.fetchSub(1, .monotonic);
    }
    
    pub fn wait(self: *JobSystem) void {
        while (self.pending.load(.acquire) > 0) {
            std.Thread.yield();
        }
    }
};
```

### Usage Example

```zig
fn updateFrame(job_system: *JobSystem) void {
    // Schedule independent systems as jobs
    job_system.schedule(.{ .func = gravityJob, .ctx = &world_data });
    job_system.schedule(.{ .func = pixelBufferJob, .ctx = &render_data });
    
    // Wait for all jobs to complete
    job_system.wait();
    
    // Present frame (must be on main thread)
    renderer.present();
}
```

---

## Thread Safety Considerations

### Data Races to Avoid

| Scenario | Problem | Solution |
|----------|---------|----------|
| Two threads writing same pixel | Lost update | Partition by rows |
| Reading position while writing | Torn read | Double buffer or mutex |
| ECS entity creation during iteration | Iterator invalidation | Defer to end of frame |
| Shared allocator | Contention | Thread-local allocators |

### Safe Patterns

```zig
// GOOD: Each thread writes to its own region
fn drawRowRange(buffer: []u32, start: usize, end: usize) void {
    for (start..end) |i| {
        buffer[i] = computeColor(i); // No overlap with other threads
    }
}

// BAD: Multiple threads writing overlapping regions
fn drawBox(buffer: []u32, x: i32, y: i32, size: i32) void {
    // Boxes might overlap! Need synchronization or spatial partitioning
}
```

### Atomic Operations

Use atomics for shared counters:

```zig
var entity_count = std.atomic.Value(u32).init(0);

// Safe increment from any thread
_ = entity_count.fetchAdd(1, .monotonic);

// Safe read
const count = entity_count.load(.acquire);
```

---

## Recommended Implementation Order

### Phase 1: Quick Wins (Low Effort, Good Returns)
1. Enable Flecs threading: `ecs.set_threads(world, 4)`
2. Test if systems parallelize correctly

### Phase 2: Pixel Buffer Parallelism
1. Add thread pool to Engine
2. Parallelize background gradient rendering
3. Parallelize box rendering by row

### Phase 3: Collision Optimization
1. Implement spatial hash grid
2. Parallelize collision detection per-entity

### Phase 4: Full Job System (If Needed)
1. Implement job queue with dependencies
2. Convert frame update to job-based

---

## Profiling

Before optimizing, measure:

```zig
const timer = std.time.Timer{};

timer.reset();
// ... code to measure ...
const elapsed_ns = timer.read();

std.debug.print("Operation took: {d}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
```

Or use Zig's built-in `@import("builtin").cpu` for CPU-specific counters.

Key metrics:
- Frame time breakdown (input, update, render)
- Cache misses (via perf on Linux)
- Thread utilization

---

## Platform Notes

| Platform | Threading Notes |
|----------|-----------------|
| macOS | Use GCD or std.Thread (pthread underneath) |
| Linux | std.Thread (pthread), can pin to cores |
| Windows | std.Thread (Win32 threads) |

For all platforms, Zig's `std.Thread` provides a consistent interface.
