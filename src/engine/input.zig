const SDL = @import("sdl2");

const PressedDirections = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const InputState = struct {
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    is_pressing: bool = false,
    quit_requested: bool = false,
    pressed_directions: PressedDirections = PressedDirections{},
    reset: bool = false,

    pub fn update(self: *InputState) void {
        while (SDL.pollEvent()) |e| {
            switch (e) {
                .quit => self.quit_requested = true,
                .mouse_motion => |m| {
                    self.mouse_x = m.x;
                    self.mouse_y = m.y;
                },
                .mouse_button_down => {
                    self.is_pressing = true;
                },
                .mouse_button_up => {
                    self.is_pressing = false;
                },
                .key_down, .key_up => |k| {
                    // Handle keyboard events here if needed
                    switch (k.keycode) {
                        .escape => {
                            if (k.key_state == .pressed) self.quit_requested = true;
                        },
                        .w, .a, .s, .d => {
                            const is_pressed = k.key_state == .pressed;
                            switch (k.keycode) {
                                .w => self.pressed_directions.up = is_pressed,
                                .a => self.pressed_directions.left = is_pressed,
                                .s => self.pressed_directions.down = is_pressed,
                                .d => self.pressed_directions.right = is_pressed,
                                else => {},
                            }
                        },
                        .r => {
                            if (k.key_state == .pressed and k.is_repeat == false) {
                                self.reset = true;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
};
