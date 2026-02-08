const SDL = @import("sdl2");
const std = @import("std");

const AXIS_MAX: f32 = 32767.0; // 32767

const PressedDirections = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

const DirectionsWithShooting = struct {
    pressed_directions: PressedDirections,
    is_pressing: bool = false,
};

const MouseState = struct {
    is_pressing: bool = false,
};

pub const InputState = struct {
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    is_pressing: bool = false,
    quit_requested: bool = false,
    pressed_directions: PressedDirections = PressedDirections{},
    reset: bool = false,
    controller: ?SDL.GameController = null,
    right_stick_x: f32 = 0.0,
    right_stick_y: f32 = 0.0,
    debug_mode: bool = false,

    keyboard_state: DirectionsWithShooting = DirectionsWithShooting{
        .pressed_directions = PressedDirections{},
    },
    dpad_state: DirectionsWithShooting = DirectionsWithShooting{
        .pressed_directions = PressedDirections{},
    },
    stick_state: DirectionsWithShooting = DirectionsWithShooting{
        .pressed_directions = PressedDirections{},
    },
    mouse_state: MouseState = MouseState{},
    d_pad_a_pressed: bool = false,

    pub fn update(self: *InputState) void {
        while (SDL.pollEvent()) |e| {
            switch (e) {
                .quit => self.quit_requested = true,
                .controller_device_added => |c| {
                    const c_which_i32_as_u_31: u31 = @intCast(c.which);
                    if (self.controller == null) {
                        self.controller = SDL.GameController.open(c_which_i32_as_u_31) catch null;
                    }
                },
                // .controller_device_added => |c| {

                // pub const SDL_ControllerDeviceEvent = extern struct {
                //     type: u32,
                //     timestamp: u32,
                //     which: i32,
                // };

                // },
                .controller_device_removed => |_| {
                    if (self.controller) |ctrl| {
                        ctrl.close();
                        self.controller = null;
                    }
                },
                .controller_button_down, .controller_button_up => |c| {
                    // std.log.debug("Controller button event: {any}", .{c});
                    const is_pressed = c.button_state == .pressed;
                    switch (c.button) {
                        .dpad_up => self.dpad_state.pressed_directions.up = is_pressed,
                        .dpad_down => self.dpad_state.pressed_directions.down = is_pressed,
                        .dpad_left => self.dpad_state.pressed_directions.left = is_pressed,
                        .dpad_right => self.dpad_state.pressed_directions.right = is_pressed,
                        .start => {
                            if (is_pressed) self.reset = true;
                        },
                        .back => {
                            if (is_pressed) self.quit_requested = true;
                        },
                        .a => { // Cross on DS4
                            self.d_pad_a_pressed = is_pressed;
                        },
                        .right_shoulder => {
                            self.dpad_state.is_pressing = is_pressed;
                        },
                        else => {},
                    }
                },
                .controller_axis_motion => |c| {
                    const deadzone = 8000;
                    switch (c.axis) {
                        .left_x => {
                            self.stick_state.pressed_directions.right = c.value > deadzone;
                            self.stick_state.pressed_directions.left = c.value < -deadzone;
                        },
                        .left_y => {
                            self.stick_state.pressed_directions.down = c.value > deadzone;
                            self.stick_state.pressed_directions.up = c.value < -deadzone;
                        },
                        .right_x => {
                            if (@abs(c.value) > deadzone) {
                                self.right_stick_x = @as(f32, @floatFromInt(c.value)) / AXIS_MAX;
                            } else {
                                self.right_stick_x = 0.0;
                            }
                        },
                        .right_y => {
                            if (@abs(c.value) > deadzone) {
                                self.right_stick_y = @as(f32, @floatFromInt(c.value)) / AXIS_MAX;
                            } else {
                                self.right_stick_y = 0.0;
                            }
                        },
                        else => {},
                    }
                },
                .mouse_motion => |m| {
                    self.mouse_x = m.x;
                    self.mouse_y = m.y;
                },
                .mouse_button_down => |m| {
                    _ = m;
                    // m.button // left, middle, right
                    self.mouse_state.is_pressing = true;
                },
                .mouse_button_up => {
                    self.mouse_state.is_pressing = false;
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
                                .w => self.keyboard_state.pressed_directions.up = is_pressed,
                                .a => self.keyboard_state.pressed_directions.left = is_pressed,
                                .s => self.keyboard_state.pressed_directions.down = is_pressed,
                                .d => self.keyboard_state.pressed_directions.right = is_pressed,
                                else => {},
                            }
                        },
                        .r => {
                            if (k.key_state == .pressed and k.is_repeat == false) {
                                self.reset = true;
                            }
                        },
                        .grave => {
                            if (k.key_state == .pressed and k.is_repeat == false) {
                                self.debug_mode = !self.debug_mode;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
            self.pressed_directions.up = self.keyboard_state.pressed_directions.up or self.dpad_state.pressed_directions.up or self.stick_state.pressed_directions.up or self.d_pad_a_pressed;
            self.pressed_directions.down = self.keyboard_state.pressed_directions.down or self.dpad_state.pressed_directions.down or self.stick_state.pressed_directions.down;
            self.pressed_directions.left = self.keyboard_state.pressed_directions.left or self.dpad_state.pressed_directions.left or self.stick_state.pressed_directions.left;
            self.pressed_directions.right = self.keyboard_state.pressed_directions.right or self.dpad_state.pressed_directions.right or self.stick_state.pressed_directions.right;
            self.is_pressing = self.dpad_state.is_pressing or self.mouse_state.is_pressing;
        }
    }
};
