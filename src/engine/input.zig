const sdl = @import("sdl3");
const std = @import("std");

const AXIS_MAX: f32 = 32767.0;

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

const ActiveInputMethod = enum {
    controller,
    keyboard_mouse,
};

pub const InputState = struct {
    mouse_x: f32 = 0.0,
    mouse_y: f32 = 0.0,
    is_pressing: bool = false,
    quit_requested: bool = false,
    pressed_directions: PressedDirections = PressedDirections{},
    reset: bool = false,
    controller: ?*sdl.SDL_Gamepad = null,
    right_stick_x: f32 = 0.0,
    right_stick_y: f32 = 0.0,
    debug_mode: bool = false,
    active_input_method: ?ActiveInputMethod = null,

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

    pub fn deinit(self: *InputState) void {
        if (self.controller) |ctrl| {
            sdl.SDL_CloseGamepad(ctrl);
            self.controller = null;
        }
    }

    pub fn update(self: *InputState) void {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => self.quit_requested = true,
                sdl.SDL_EVENT_GAMEPAD_ADDED => {
                    if (self.controller == null) {
                        self.controller = sdl.SDL_OpenGamepad(event.gdevice.which);
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_REMOVED => {
                    if (self.controller) |ctrl| {
                        if (sdl.SDL_GetGamepadID(ctrl) == event.gdevice.which) {
                            sdl.SDL_CloseGamepad(ctrl);
                            self.controller = null;
                        }
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, sdl.SDL_EVENT_GAMEPAD_BUTTON_UP => {
                    const is_pressed = event.gbutton.down;
                    if (is_pressed) self.active_input_method = .controller;
                    switch (@as(c_int, event.gbutton.button)) {
                        sdl.SDL_GAMEPAD_BUTTON_DPAD_UP => self.dpad_state.pressed_directions.up = is_pressed,
                        sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN => self.dpad_state.pressed_directions.down = is_pressed,
                        sdl.SDL_GAMEPAD_BUTTON_DPAD_LEFT => self.dpad_state.pressed_directions.left = is_pressed,
                        sdl.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => self.dpad_state.pressed_directions.right = is_pressed,
                        sdl.SDL_GAMEPAD_BUTTON_START => {
                            if (is_pressed) self.reset = true;
                        },
                        sdl.SDL_GAMEPAD_BUTTON_BACK => {
                            if (is_pressed) self.quit_requested = true;
                        },
                        sdl.SDL_GAMEPAD_BUTTON_SOUTH => { // Cross on DS4
                            self.d_pad_a_pressed = is_pressed;
                        },
                        sdl.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER => {
                            self.dpad_state.is_pressing = is_pressed;
                        },
                        else => {},
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
                    const deadzone: i32 = 8000;
                    const value: i32 = event.gaxis.value;
                    const respond_to_change = @abs(value) > deadzone;
                    if (respond_to_change) self.active_input_method = .controller;
                    switch (@as(c_int, event.gaxis.axis)) {
                        sdl.SDL_GAMEPAD_AXIS_LEFTX => {
                            self.stick_state.pressed_directions.right = value > deadzone;
                            self.stick_state.pressed_directions.left = value < -deadzone;
                        },
                        sdl.SDL_GAMEPAD_AXIS_LEFTY => {
                            self.stick_state.pressed_directions.down = value > deadzone;
                            self.stick_state.pressed_directions.up = value < -deadzone;
                        },
                        sdl.SDL_GAMEPAD_AXIS_RIGHTX => {
                            if (respond_to_change) {
                                self.right_stick_x = @as(f32, @floatFromInt(value)) / AXIS_MAX;
                            } else {
                                self.right_stick_x = 0.0;
                            }
                        },
                        sdl.SDL_GAMEPAD_AXIS_RIGHTY => {
                            if (respond_to_change) {
                                self.right_stick_y = @as(f32, @floatFromInt(value)) / AXIS_MAX;
                            } else {
                                self.right_stick_y = 0.0;
                            }
                        },
                        else => {},
                    }
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    self.active_input_method = .keyboard_mouse;
                    self.mouse_x = event.motion.x;
                    self.mouse_y = event.motion.y;
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                    self.active_input_method = .keyboard_mouse;
                    if (event.button.button == sdl.SDL_BUTTON_LEFT) {
                        self.mouse_state.is_pressing = event.button.down;
                    }
                },
                sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                    const is_pressed = event.key.down;
                    if (is_pressed) self.active_input_method = .keyboard_mouse;
                    switch (event.key.key) {
                        sdl.SDLK_ESCAPE => {
                            if (is_pressed) self.quit_requested = true;
                        },
                        sdl.SDLK_W => self.keyboard_state.pressed_directions.up = is_pressed,
                        sdl.SDLK_A => self.keyboard_state.pressed_directions.left = is_pressed,
                        sdl.SDLK_S => self.keyboard_state.pressed_directions.down = is_pressed,
                        sdl.SDLK_D => self.keyboard_state.pressed_directions.right = is_pressed,
                        sdl.SDLK_R => {
                            if (is_pressed and !event.key.repeat) {
                                self.reset = true;
                            }
                        },
                        sdl.SDLK_GRAVE => {
                            if (is_pressed and !event.key.repeat) {
                                self.debug_mode = !self.debug_mode;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        self.pressed_directions.up = self.keyboard_state.pressed_directions.up or self.dpad_state.pressed_directions.up or self.stick_state.pressed_directions.up or self.d_pad_a_pressed;
        self.pressed_directions.down = self.keyboard_state.pressed_directions.down or self.dpad_state.pressed_directions.down or self.stick_state.pressed_directions.down;
        self.pressed_directions.left = self.keyboard_state.pressed_directions.left or self.dpad_state.pressed_directions.left or self.stick_state.pressed_directions.left;
        self.pressed_directions.right = self.keyboard_state.pressed_directions.right or self.dpad_state.pressed_directions.right or self.stick_state.pressed_directions.right;
        self.is_pressing = self.dpad_state.is_pressing or self.mouse_state.is_pressing;
    }
};
