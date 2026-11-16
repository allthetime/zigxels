const std = @import("std");
const c2 = @import("zig_c2");
const pixels = @import("../engine/pixels.zig");
const Effect = @import("../engine/effects.zig").Effect;

pub const CELL_SIZE: usize = 4;

pub const Material = enum(u8) {
    air = 0,
    rock = 1,
    sand = 2,
    liquid_purple = 3,
    liquid_water = 4,

    pub fn isSolid(self: Material) bool {
        return self == .rock or self == .sand;
    }

    pub fn isLiquid(self: Material) bool {
        return self == .liquid_purple or self == .liquid_water;
    }
};

pub const Cell = packed struct(u32) {
    material: Material = .air,
    color_variant: u4 = 0,
    indestructible: bool = false,
    _pad: u3 = 0,
    updated_tick: u16 = 0,
};

pub const RaycastHit = struct {
    t: f32,
    world_x: f32,
    world_y: f32,
    cell_x: i32,
    cell_y: i32,
    normal: c2.Vec2,
    material: Material,
    indestructible: bool,
};

pub const MaterialCounts = struct {
    rock_cells: u32 = 0,
    sand_cells: u32 = 0,
    liquid_purple_cells: u32 = 0,
    liquid_water_cells: u32 = 0,

    pub fn totalLiquid(self: MaterialCounts) u32 {
        return self.liquid_purple_cells + self.liquid_water_cells;
    }
};

pub const MaterialGrid = struct {
    cells: []Cell = &.{},
    allocator: ?std.mem.Allocator = null,
    width: usize = 0,
    height: usize = 0,
    cell_size: usize = CELL_SIZE,
    tick: u16 = 0,
    active_cells: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize, cell_size: usize) !MaterialGrid {
        std.debug.assert(cell_size > 0);
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, Cell{});
        return .{
            .cells = cells,
            .allocator = allocator,
            .width = width,
            .height = height,
            .cell_size = cell_size,
            .tick = 0,
            .active_cells = 0,
        };
    }

    pub fn initForPixels(allocator: std.mem.Allocator, pixel_width: usize, pixel_height: usize, cell_size: usize) !MaterialGrid {
        const w = (pixel_width + cell_size - 1) / cell_size;
        const h = (pixel_height + cell_size - 1) / cell_size;
        return init(allocator, w, h, cell_size);
    }

    pub fn deinit(self: *MaterialGrid) void {
        if (self.allocator) |alloc| {
            if (self.cells.len > 0) {
                alloc.free(self.cells);
            }
        }
        self.cells = &.{};
        self.allocator = null;
        self.width = 0;
        self.height = 0;
        self.tick = 0;
        self.active_cells = 0;
    }

    pub fn clear(self: *MaterialGrid) void {
        @memset(self.cells, Cell{});
        self.tick = 0;
        self.active_cells = 0;
    }

    pub inline fn cellSizeF(self: MaterialGrid) f32 {
        return @floatFromInt(self.cell_size);
    }

    pub inline fn inBounds(self: MaterialGrid, gx: i32, gy: i32) bool {
        return gx >= 0 and gy >= 0 and gx < @as(i32, @intCast(self.width)) and gy < @as(i32, @intCast(self.height));
    }

    pub inline fn worldToCellX(self: MaterialGrid, wx: f32) i32 {
        return @intFromFloat(@floor(wx / self.cellSizeF()));
    }

    pub inline fn worldToCellY(self: MaterialGrid, wy: f32) i32 {
        return @intFromFloat(@floor(wy / self.cellSizeF()));
    }

    pub inline fn cellToWorldMinX(self: MaterialGrid, gx: i32) f32 {
        return @as(f32, @floatFromInt(gx)) * self.cellSizeF();
    }

    pub inline fn cellToWorldMinY(self: MaterialGrid, gy: i32) f32 {
        return @as(f32, @floatFromInt(gy)) * self.cellSizeF();
    }

    pub inline fn cellToWorldCenterX(self: MaterialGrid, gx: i32) f32 {
        return (@as(f32, @floatFromInt(gx)) + 0.5) * self.cellSizeF();
    }

    pub inline fn cellToWorldCenterY(self: MaterialGrid, gy: i32) f32 {
        return (@as(f32, @floatFromInt(gy)) + 0.5) * self.cellSizeF();
    }

    pub inline fn cellWorldAABB(self: MaterialGrid, gx: i32, gy: i32) c2.AABB {
        const min_x = self.cellToWorldMinX(gx);
        const min_y = self.cellToWorldMinY(gy);
        const cs = self.cellSizeF();
        return .{
            .min = .{ .x = min_x, .y = min_y },
            .max = .{ .x = min_x + cs, .y = min_y + cs },
        };
    }

    inline fn cellIndex(self: MaterialGrid, gx: i32, gy: i32) usize {
        return @as(usize, @intCast(gy)) * self.width + @as(usize, @intCast(gx));
    }

    pub fn getCell(self: *const MaterialGrid, gx: i32, gy: i32) ?Cell {
        if (!self.inBounds(gx, gy)) return null;
        return self.cells[self.cellIndex(gx, gy)];
    }

    pub fn setCell(self: *MaterialGrid, gx: i32, gy: i32, cell: Cell) void {
        if (!self.inBounds(gx, gy)) return;
        self.cells[self.cellIndex(gx, gy)] = cell;
    }

    pub fn setMaterial(self: *MaterialGrid, gx: i32, gy: i32, mat: Material) void {
        self.setCell(gx, gy, .{
            .material = mat,
            .color_variant = variantForCoord(gx, gy, self.tick),
            .indestructible = false,
            .updated_tick = 0,
        });
    }

    pub fn fillCellRect(
        self: *MaterialGrid,
        min_gx: i32,
        min_gy: i32,
        max_gx_excl: i32,
        max_gy_excl: i32,
        mat: Material,
        indestructible: bool,
    ) void {
        if (self.width == 0 or self.height == 0) return;
        const w_i: i32 = @intCast(self.width);
        const h_i: i32 = @intCast(self.height);
        const x0 = @max(0, min_gx);
        const y0 = @max(0, min_gy);
        const x1 = @min(w_i, max_gx_excl);
        const y1 = @min(h_i, max_gy_excl);
        if (x1 <= x0 or y1 <= y0) return;

        var gy = y0;
        while (gy < y1) : (gy += 1) {
            var gx = x0;
            while (gx < x1) : (gx += 1) {
                self.cells[self.cellIndex(gx, gy)] = .{
                    .material = mat,
                    .color_variant = variantForCoord(gx, gy, 0),
                    .indestructible = indestructible,
                    .updated_tick = 0,
                };
            }
        }
    }

    pub fn isSolidAtCell(self: *const MaterialGrid, gx: i32, gy: i32) bool {
        const cell = self.getCell(gx, gy) orelse return false;
        return cell.material.isSolid();
    }

    pub fn carveCircle(self: *MaterialGrid, cx: f32, cy: f32, radius_px: f32) u32 {
        return self.carveCircleWithDebris(cx, cy, radius_px, 0.0);
    }

    pub fn carveCircleWithDebris(self: *MaterialGrid, cx: f32, cy: f32, radius_px: f32, debris_chance: f32) u32 {
        if (self.width == 0 or self.height == 0 or radius_px <= 0.0) return 0;
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(radius_px)) return 0;

        const min_gx = @max(0, self.worldToCellX(cx - radius_px));
        const max_gx = @min(@as(i32, @intCast(self.width)) - 1, self.worldToCellX(cx + radius_px));
        const min_gy = @max(0, self.worldToCellY(cy - radius_px));
        const max_gy = @min(@as(i32, @intCast(self.height)) - 1, self.worldToCellY(cy + radius_px));
        if (max_gx < min_gx or max_gy < min_gy) return 0;

        const r_sq = radius_px * radius_px;
        const threshold: u32 = if (debris_chance <= 0.0)
            0
        else if (debris_chance >= 1.0)
            1000
        else
            @intFromFloat(debris_chance * 1000.0);

        var carved: u32 = 0;
        var gy = min_gy;
        while (gy <= max_gy) : (gy += 1) {
            const wy = self.cellToWorldCenterY(gy);
            const dy = wy - cy;
            var gx = min_gx;
            while (gx <= max_gx) : (gx += 1) {
                const wx = self.cellToWorldCenterX(gx);
                const dx = wx - cx;
                if (dx * dx + dy * dy > r_sq) continue;

                const idx = self.cellIndex(gx, gy);
                const cell = self.cells[idx];
                if (cell.indestructible) continue;
                if (cell.material == .rock or cell.material == .sand) {
                    const was_rock = cell.material == .rock;
                    carved += 1;
                    if (was_rock and threshold > 0 and (coordHash(@intCast(gx), @intCast(gy), self.tick) % 1000) < threshold) {
                        self.cells[idx] = .{
                            .material = .sand,
                            .color_variant = variantForCoord(gx, gy, self.tick),
                            .indestructible = false,
                            .updated_tick = 0,
                        };
                    } else {
                        self.cells[idx] = Cell{};
                    }
                }
            }
        }
        return carved;
    }

    pub fn spawnSplash(self: *MaterialGrid, cx: f32, cy: f32, radius_px: f32, mat: Material) u32 {
        if (self.width == 0 or self.height == 0 or mat == .air) return 0;
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(radius_px) or radius_px < 0.0) return 0;

        const min_gx = @max(0, self.worldToCellX(cx - radius_px));
        const max_gx = @min(@as(i32, @intCast(self.width)) - 1, self.worldToCellX(cx + radius_px));
        const min_gy = @max(0, self.worldToCellY(cy - radius_px));
        const max_gy = @min(@as(i32, @intCast(self.height)) - 1, self.worldToCellY(cy + radius_px));
        if (max_gx < min_gx or max_gy < min_gy) return 0;

        const r_sq = radius_px * radius_px;
        var spawned: u32 = 0;

        var gy = min_gy;
        while (gy <= max_gy) : (gy += 1) {
            const wy = self.cellToWorldCenterY(gy);
            const dy = wy - cy;
            var gx = min_gx;
            while (gx <= max_gx) : (gx += 1) {
                const wx = self.cellToWorldCenterX(gx);
                const dx = wx - cx;
                if (dx * dx + dy * dy > r_sq) continue;

                const idx = self.cellIndex(gx, gy);
                if (self.cells[idx].material == .air) {
                    self.cells[idx] = .{
                        .material = mat,
                        .color_variant = variantForCoord(gx, gy, self.tick),
                        .indestructible = false,
                        .updated_tick = 0,
                    };
                    spawned += 1;
                }
            }
        }
        return spawned;
    }

    /// Grid DDA ray-march from `(x0, y0)` to `(x1, y1)` in world pixels.
    /// Returns the first blocking material cell hit along the segment, or `null`.
    pub fn raycastSegment(
        self: *const MaterialGrid,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        hit_liquids: bool,
    ) ?RaycastHit {
        if (self.width == 0 or self.height == 0) return null;
        if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or !std.math.isFinite(x1) or !std.math.isFinite(y1)) return null;

        const cs = self.cellSizeF();
        const gx0 = x0 / cs;
        const gy0 = y0 / cs;
        const gx1 = x1 / cs;
        const gy1 = y1 / cs;

        var ix: i32 = @intFromFloat(@floor(gx0));
        var iy: i32 = @intFromFloat(@floor(gy0));
        const end_ix: i32 = @intFromFloat(@floor(gx1));
        const end_iy: i32 = @intFromFloat(@floor(gy1));

        const dx = x1 - x0;
        const dy = y1 - y0;

        if (self.getCell(ix, iy)) |start_cell| {
            if (isBlockingRay(start_cell.material, hit_liquids)) {
                const len = @sqrt(dx * dx + dy * dy);
                const normal = if (len > 1e-5)
                    c2.Vec2{ .x = -dx / len, .y = -dy / len }
                else
                    c2.Vec2{ .x = 0.0, .y = -1.0 };
                return .{
                    .t = 0.0,
                    .world_x = x0,
                    .world_y = y0,
                    .cell_x = ix,
                    .cell_y = iy,
                    .normal = normal,
                    .material = start_cell.material,
                    .indestructible = start_cell.indestructible,
                };
            }
        }

        const dgx = gx1 - gx0;
        const dgy = gy1 - gy0;
        if (@abs(dgx) <= 1e-7 and @abs(dgy) <= 1e-7) return null;
        if (ix == end_ix and iy == end_iy) return null;

        const step_x: i32 = if (dgx > 0.0) 1 else if (dgx < 0.0) -1 else 0;
        const step_y: i32 = if (dgy > 0.0) 1 else if (dgy < 0.0) -1 else 0;

        const t_delta_x: f32 = if (step_x != 0) @abs(1.0 / dgx) else std.math.inf(f32);
        const t_delta_y: f32 = if (step_y != 0) @abs(1.0 / dgy) else std.math.inf(f32);

        var t_max_x: f32 = if (step_x > 0)
            (@as(f32, @floatFromInt(ix + 1)) - gx0) / dgx
        else if (step_x < 0)
            (gx0 - @as(f32, @floatFromInt(ix))) / (-dgx)
        else
            std.math.inf(f32);

        var t_max_y: f32 = if (step_y > 0)
            (@as(f32, @floatFromInt(iy + 1)) - gy0) / dgy
        else if (step_y < 0)
            (gy0 - @as(f32, @floatFromInt(iy))) / (-dgy)
        else
            std.math.inf(f32);

        const max_steps: usize = @intCast(@abs(end_ix - ix) + @abs(end_iy - iy) + 4);
        for (0..max_steps) |_| {
            var t_hit: f32 = 0.0;
            var normal = c2.Vec2{ .x = 0.0, .y = 0.0 };

            if (t_max_x < t_max_y) {
                if (t_max_x > 1.0 + 1e-5) break;
                t_hit = std.math.clamp(t_max_x, 0.0, 1.0);
                ix += step_x;
                t_max_x += t_delta_x;
                normal = .{ .x = -@as(f32, @floatFromInt(step_x)), .y = 0.0 };
            } else {
                if (t_max_y > 1.0 + 1e-5) break;
                t_hit = std.math.clamp(t_max_y, 0.0, 1.0);
                iy += step_y;
                t_max_y += t_delta_y;
                normal = .{ .x = 0.0, .y = -@as(f32, @floatFromInt(step_y)) };
            }

            if (self.getCell(ix, iy)) |cell| {
                if (isBlockingRay(cell.material, hit_liquids)) {
                    return .{
                        .t = t_hit,
                        .world_x = x0 + dx * t_hit,
                        .world_y = y0 + dy * t_hit,
                        .cell_x = ix,
                        .cell_y = iy,
                        .normal = normal,
                        .material = cell.material,
                        .indestructible = cell.indestructible,
                    };
                }
            }
        }

        return null;
    }

    fn isBlockingRay(mat: Material, hit_liquids: bool) bool {
        if (mat.isSolid()) return true;
        if (hit_liquids and mat.isLiquid()) return true;
        return false;
    }

    /// Check if `aabb` overlaps any solid (`rock`/`sand`) grid cell.
    pub fn aabbOverlapsSolid(
        self: *const MaterialGrid,
        aabb: c2.AABB,
        checks_out: ?*u32,
        hits_out: ?*u32,
    ) bool {
        if (self.width == 0 or self.height == 0) return false;
        const min_gx = @max(0, self.worldToCellX(aabb.min.x));
        const max_gx = @min(@as(i32, @intCast(self.width)) - 1, self.worldToCellX(aabb.max.x - 0.0001));
        const min_gy = @max(0, self.worldToCellY(aabb.min.y));
        const max_gy = @min(@as(i32, @intCast(self.height)) - 1, self.worldToCellY(aabb.max.y - 0.0001));
        if (max_gx < min_gx or max_gy < min_gy) return false;

        var gy = min_gy;
        while (gy <= max_gy) : (gy += 1) {
            var gx = min_gx;
            while (gx <= max_gx) : (gx += 1) {
                if (checks_out) |c| c.* += 1;
                if (self.isSolidAtCell(gx, gy)) {
                    if (hits_out) |h| h.* += 1;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn stepMaterials(self: *MaterialGrid) void {
        if (self.width == 0 or self.height == 0) return;

        self.tick +%= 1;
        if (self.tick == 0) {
            for (self.cells) |*c| {
                c.updated_tick = 0;
            }
            self.tick = 1;
        }

        const cur_tick = self.tick;
        const w = self.width;
        const h = self.height;
        const w_i: i32 = @intCast(w);
        const h_i: i32 = @intCast(h);
        const left_to_right = (cur_tick & 1) == 1;
        var moved: u32 = 0;

        var y_rev: usize = 0;
        while (y_rev < h) : (y_rev += 1) {
            const y = h - 1 - y_rev;
            var x_step: usize = 0;
            while (x_step < w) : (x_step += 1) {
                const x = if (left_to_right) x_step else (w - 1 - x_step);
                const idx = y * w + x;
                const cell = self.cells[idx];
                if (cell.material == .air or cell.material == .rock) continue;
                if (cell.updated_tick == cur_tick) continue;

                const hash = coordHash(x, y, cur_tick);
                const first_dx: i32 = if ((hash & 1) == 0) -1 else 1;
                const second_dx: i32 = -first_dx;

                switch (cell.material) {
                    .sand => {
                        if (y + 1 < h) {
                            const below_idx = (y + 1) * w + x;
                            const below_mat = self.cells[below_idx].material;
                            if (below_mat == .air or below_mat.isLiquid()) {
                                self.swapCells(idx, below_idx, cur_tick);
                                moved += 1;
                                continue;
                            }

                            const x_i: i32 = @intCast(x);
                            const ny: usize = y + 1;
                            for ([2]i32{ first_dx, second_dx }) |dx| {
                                const nx_i = x_i + dx;
                                if (nx_i < 0 or nx_i >= w_i) continue;
                                const nx: usize = @intCast(nx_i);
                                // Block diagonal squeeze through sealed rock corners
                                if (self.cells[y * w + nx].material == .rock and below_mat == .rock) continue;
                                const diag_idx = ny * w + nx;
                                const diag_mat = self.cells[diag_idx].material;
                                if (diag_mat == .air or diag_mat.isLiquid()) {
                                    self.swapCells(idx, diag_idx, cur_tick);
                                    moved += 1;
                                    break;
                                }
                            }
                        }
                    },
                    .liquid_purple, .liquid_water => {
                        const x_i: i32 = @intCast(x);
                        var did_move = false;

                        if (y + 1 < h) {
                            const below_idx = (y + 1) * w + x;
                            const below_mat = self.cells[below_idx].material;
                            if (below_mat == .air or (cell.material == .liquid_purple and below_mat == .liquid_water)) {
                                self.swapCells(idx, below_idx, cur_tick);
                                moved += 1;
                                continue;
                            }

                            const ny: usize = y + 1;
                            for ([2]i32{ first_dx, second_dx }) |dx| {
                                const nx_i = x_i + dx;
                                if (nx_i < 0 or nx_i >= w_i) continue;
                                const nx: usize = @intCast(nx_i);
                                const side_mat = self.cells[y * w + nx].material;
                                if (side_mat.isSolid() and below_mat.isSolid()) continue;

                                const diag_idx = ny * w + nx;
                                const diag_mat = self.cells[diag_idx].material;
                                if (diag_mat == .air or (cell.material == .liquid_purple and diag_mat == .liquid_water)) {
                                    self.swapCells(idx, diag_idx, cur_tick);
                                    moved += 1;
                                    did_move = true;
                                    break;
                                }
                            }
                            if (did_move) continue;
                        }

                        // Horizontal flow without directional bias (up to 2 clear cells if supported below)
                        const can_fall_below = (y + 1 < h);
                        for ([2]i32{ first_dx, second_dx }) |dx| {
                            const nx1_i = x_i + dx;
                            if (nx1_i < 0 or nx1_i >= w_i) continue;
                            const nx1: usize = @intCast(nx1_i);
                            const idx1 = y * w + nx1;
                            if (self.cells[idx1].material != .air) continue;

                            var dest_idx = idx1;
                            const nx2_i = x_i + dx * 2;
                            if (nx2_i >= 0 and nx2_i < w_i) {
                                const nx2: usize = @intCast(nx2_i);
                                const drop1 = can_fall_below and self.cells[(y + 1) * w + nx1].material == .air;
                                if (!drop1 and self.cells[y * w + nx2].material == .air) {
                                    dest_idx = y * w + nx2;
                                }
                            }

                            self.swapCells(idx, dest_idx, cur_tick);
                            moved += 1;
                            break;
                        }
                    },
                    .air, .rock => {},
                }
            }
        }

        _ = h_i;
        self.active_cells = moved;
    }

    inline fn swapCells(self: *MaterialGrid, a_idx: usize, b_idx: usize, cur_tick: u16) void {
        const tmp = self.cells[a_idx];
        self.cells[a_idx] = self.cells[b_idx];
        self.cells[b_idx] = tmp;
        self.cells[a_idx].updated_tick = cur_tick;
        self.cells[b_idx].updated_tick = cur_tick;
    }

    pub fn countByMaterial(self: *const MaterialGrid) MaterialCounts {
        var counts = MaterialCounts{};
        for (self.cells) |cell| {
            switch (cell.material) {
                .air => {},
                .rock => counts.rock_cells += 1,
                .sand => counts.sand_cells += 1,
                .liquid_purple => counts.liquid_purple_cells += 1,
                .liquid_water => counts.liquid_water_cells += 1,
            }
        }
        return counts;
    }

    pub fn renderToBuffers(
        self: *const MaterialGrid,
        pixel_buffer: []u32,
        effect_buffer: []u16,
        buf_width: usize,
        buf_height: usize,
    ) void {
        if (self.width == 0 or self.height == 0 or buf_width == 0 or buf_height == 0) return;

        const cs = self.cell_size;
        const w = self.width;
        const h = self.height;

        for (0..h) |gy| {
            const py_start = gy * cs;
            if (py_start >= buf_height) break;
            const py_end = @min(py_start + cs, buf_height);
            const row_cell_base = gy * w;

            for (0..w) |gx| {
                const cell = self.cells[row_cell_base + gx];
                if (cell.material == .air) continue;

                const px_start = gx * cs;
                if (px_start >= buf_width) break;
                const px_end = @min(px_start + cs, buf_width);

                const top_is_air = gy > 0 and self.cells[(gy - 1) * w + gx].material == .air;
                const col = colorForCell(cell, top_is_air);

                switch (cell.material) {
                    .liquid_water => {
                        const alpha: u8 = 195;
                        for (py_start..py_end) |py| {
                            const row = py * buf_width;
                            for (px_start..px_end) |px| {
                                const idx = row + px;
                                pixel_buffer[idx] = pixels.blendPixel(pixel_buffer[idx], col, alpha);
                            }
                        }
                    },
                    .liquid_purple => {
                        const fx_val = Effect.glow_only.withIntensity(130);
                        for (py_start..py_end) |py| {
                            const row = py * buf_width;
                            @memset(pixel_buffer[row + px_start .. row + px_end], col);
                            for (effect_buffer[row + px_start .. row + px_end]) |*efx| {
                                const existing_flags: u8 = @truncate(efx.*);
                                const existing_int: u8 = @truncate(efx.* >> 8);
                                const merged_flags = existing_flags | Effect.glow_only.toByte();
                                const merged_int = @max(existing_int, @as(u8, @truncate(fx_val >> 8)));
                                efx.* = (@as(u16, merged_int) << 8) | @as(u16, merged_flags);
                            }
                        }
                    },
                    else => {
                        if (px_end - px_start == 4) {
                            const quad_col: [4]u32 = @splat(col);
                            for (py_start..py_end) |py| {
                                const row = py * buf_width + px_start;
                                pixel_buffer[row..][0..4].* = quad_col;
                            }
                        } else {
                            for (py_start..py_end) |py| {
                                const row = py * buf_width;
                                @memset(pixel_buffer[row + px_start .. row + px_end], col);
                            }
                        }
                    },
                }
            }
        }
    }
};

fn colorForCell(cell: Cell, top_is_air: bool) u32 {
    const v: i32 = @as(i32, cell.color_variant) - 7; // -7..+8
    return switch (cell.material) {
        .air => 0,
        .rock => if (cell.indestructible) blk: {
            const r = clampU8(42 + @divTrunc(v, 2));
            const g = clampU8(46 + @divTrunc(v, 2));
            const b = clampU8(58 + @divTrunc(v, 2));
            break :blk pixels.packColor(r, g, b, 255);
        } else if (top_is_air) blk: {
            const r = clampU8(116 + v);
            const g = clampU8(136 + v);
            const b = clampU8(92 + v);
            break :blk pixels.packColor(r, g, b, 255);
        } else blk: {
            const r = clampU8(90 + v * 2);
            const g = clampU8(82 + v * 2);
            const b = clampU8(72 + v * 2);
            break :blk pixels.packColor(r, g, b, 255);
        },
        .sand => blk: {
            const r = clampU8(226 + v * 2);
            const g = clampU8(188 + v * 2);
            const b = clampU8(102 + v);
            break :blk pixels.packColor(r, g, b, 255);
        },
        .liquid_purple => blk: {
            const r = clampU8(192 + v * 2);
            const g = clampU8(56 + v);
            const b = clampU8(244 + v);
            break :blk pixels.packColor(r, g, b, 255);
        },
        .liquid_water => blk: {
            const r = clampU8(48 + v);
            const g = clampU8(160 + v * 2);
            const b = clampU8(236 + v);
            break :blk pixels.packColor(r, g, b, 255);
        },
    };
}

inline fn clampU8(val: i32) u8 {
    return @intCast(std.math.clamp(val, 0, 255));
}

inline fn coordHash(x: usize, y: usize, tick: u16) u32 {
    var h: u32 = @as(u32, @truncate(x)) *% 73856093;
    h ^= @as(u32, @truncate(y)) *% 19349663;
    h ^= @as(u32, tick) *% 83492791;
    h ^= h >> 16;
    h *%= 0x45d9f3b;
    h ^= h >> 16;
    return h;
}

inline fn variantForCoord(gx: i32, gy: i32, tick: u16) u4 {
    const ux: usize = @bitCast(@as(isize, gx));
    const uy: usize = @bitCast(@as(isize, gy));
    return @truncate(coordHash(ux, uy, tick));
}

test "MaterialGrid getCell, setCell, carveCircle, and spawnSplash respect bounds and indestructible rock" {
    const testing = std.testing;
    var grid = try MaterialGrid.init(testing.allocator, 16, 16, 4);
    defer grid.deinit();

    // Out of bounds returns null and setCell is safe no-op
    try testing.expectEqual(@as(?Cell, null), grid.getCell(-1, 0));
    try testing.expectEqual(@as(?Cell, null), grid.getCell(16, 5));
    grid.setMaterial(-2, -2, .rock);

    // Fill destructible rock block and one indestructible border row
    grid.fillCellRect(4, 4, 12, 12, .rock, false);
    grid.fillCellRect(4, 11, 12, 12, .rock, true);

    try testing.expectEqual(Material.rock, grid.getCell(6, 6).?.material);
    try testing.expect(!grid.getCell(6, 6).?.indestructible);
    try testing.expect(grid.getCell(6, 11).?.indestructible);

    // Carve circle around cell (8, 9) -> world center (34, 38), radius 10px (~2.5 cells)
    const carved = grid.carveCircle(34.0, 38.0, 10.0);
    try testing.expect(carved > 0);
    try testing.expectEqual(Material.air, grid.getCell(8, 9).?.material);
    // Indestructible rock at row 11 must remain intact
    try testing.expectEqual(Material.rock, grid.getCell(8, 11).?.material);

    // spawnSplash fills air inside radius without overwriting surviving rock
    const spawned = grid.spawnSplash(34.0, 38.0, 10.0, .liquid_purple);
    try testing.expect(spawned > 0);
    try testing.expectEqual(Material.liquid_purple, grid.getCell(8, 9).?.material);
    try testing.expectEqual(Material.rock, grid.getCell(8, 11).?.material);
}

test "stepMaterials moves sand downward, slides diagonally, and sinks through liquid" {
    const testing = std.testing;
    var grid = try MaterialGrid.init(testing.allocator, 12, 12, 4);
    defer grid.deinit();

    // Rock floor at row 10 and rock peg at (5, 5)
    grid.fillCellRect(0, 10, 12, 11, .rock, true);
    grid.setCell(5, 5, .{ .material = .rock, .indestructible = true });

    // 1. Free-falling sand at (2, 1) reaches row 9
    grid.setMaterial(2, 1, .sand);
    for (0..12) |_| grid.stepMaterials();
    try testing.expectEqual(Material.air, grid.getCell(2, 1).?.material);
    try testing.expectEqual(Material.sand, grid.getCell(2, 9).?.material);

    // 2. Sand falling onto rock peg at (5, 5) slides diagonally off the peg to floor
    grid.setMaterial(5, 2, .sand);
    for (0..16) |_| grid.stepMaterials();
    try testing.expectEqual(Material.rock, grid.getCell(5, 5).?.material);
    try testing.expectEqual(Material.air, grid.getCell(5, 4).?.material);
    const landed_left = grid.getCell(4, 9).?.material == .sand;
    const landed_right = grid.getCell(6, 9).?.material == .sand;
    try testing.expect(landed_left or landed_right);

    // 3. Sand placed above confined water basin sinks to bottom below water
    grid.fillCellRect(7, 7, 8, 10, .rock, true);
    grid.fillCellRect(11, 7, 12, 10, .rock, true);
    grid.fillCellRect(8, 7, 11, 10, .liquid_water, false);
    grid.setMaterial(9, 5, .sand);
    for (0..16) |_| grid.stepMaterials();
    try testing.expectEqual(Material.sand, grid.getCell(9, 9).?.material);
    try testing.expectEqual(Material.liquid_water, grid.getCell(9, 7).?.material);
}

test "stepMaterials levels liquid horizontally without directional bias" {
    const testing = std.testing;
    var grid = try MaterialGrid.init(testing.allocator, 33, 12, 4);
    defer grid.deinit();

    // Sealed floor and side walls
    grid.fillCellRect(0, 10, 33, 11, .rock, true);
    grid.fillCellRect(0, 0, 1, 11, .rock, true);
    grid.fillCellRect(32, 0, 33, 11, .rock, true);

    // Vertical column of 7 water cells centered at x = 16
    for (3..10) |gy| {
        grid.setMaterial(16, @intCast(gy), .liquid_water);
    }

    for (0..120) |_| {
        grid.stepMaterials();
    }

    var water_count: usize = 0;
    var sum_x: i32 = 0;
    var max_y: usize = 0;
    for (0..grid.height) |gy| {
        for (0..grid.width) |gx| {
            if (grid.getCell(@intCast(gx), @intCast(gy)).?.material == .liquid_water) {
                water_count += 1;
                sum_x += @intCast(gx);
                if (gy < 9) max_y += 1;
            }
        }
    }

    try testing.expectEqual(@as(usize, 7), water_count);
    // All 7 cells should have leveled onto the floor row 9
    try testing.expectEqual(@as(usize, 0), max_y);
    // Center of mass remains near center x=16 (no systematic left/right drift)
    const mean_x = @as(f32, @floatFromInt(sum_x)) / 7.0;
    try testing.expectApproxEqAbs(@as(f32, 16.0), mean_x, 4.0);
}

test "MaterialGrid DDA raycastSegment detects thin 1-cell rock without tunneling" {
    const testing = std.testing;
    var grid = try MaterialGrid.init(testing.allocator, 32, 16, 4);
    defer grid.deinit();

    // Thin 1-cell-thick vertical rock wall at gx = 10 (world x = 40..44)
    grid.fillCellRect(10, 2, 11, 14, .rock, false);
    // Pool of water in front at gx = 5..7 (must NOT block bullet rays)
    grid.fillCellRect(5, 6, 8, 10, .liquid_water, false);

    // Long fast step crossing from x=8 to x=96 in a single tick (88px > 4px cell)
    const hit = grid.raycastSegment(8.0, 30.0, 96.0, 30.0, false);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(i32, 10), hit.?.cell_x);
    try testing.expectEqual(Material.rock, hit.?.material);
    try testing.expectApproxEqAbs(@as(f32, 40.0), hit.?.world_x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, -1.0), hit.?.normal.x, 0.001);

    // Segment in pure air misses cleanly
    const miss = grid.raycastSegment(8.0, 4.0, 96.0, 4.0, false);
    try testing.expect(miss == null);
}
