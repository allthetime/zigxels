const SDL = @import("sdl2");

pub const InputState = struct {
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    is_pressing: bool = false,
    quit_requested: bool = false,

    pub fn update(self: *InputState) void {
        while (SDL.pollEvent()) |e| {
            switch (e) {
                .quit => self.quit_requested = true,
                .mouse_motion => |m| {
                    self.mouse_x = m.x;
                    self.mouse_y = m.y;
                },
                .mouse_button_down => self.is_pressing = true,
                .mouse_button_up => self.is_pressing = false,
                else => {},
            }
        }
    }
};
