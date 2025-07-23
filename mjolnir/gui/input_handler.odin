package gui

import "vendor:glfw"

// Key constants (GLFW key codes)
KEY_BACKSPACE :: 259
KEY_DELETE    :: 261
KEY_LEFT      :: 263
KEY_RIGHT     :: 262  
KEY_HOME      :: 268
KEY_END       :: 269
KEY_ENTER     :: 257

InputEvent :: union {
    MouseEvent,
    KeyboardEvent,
}

MouseEventType :: enum {
    Move,
    ButtonDown,
    ButtonUp,
    Wheel,
    Enter,
    Leave,
}

MouseButton :: enum {
    Left = 0,
    Right = 1,
    Middle = 2,
}

MouseEvent :: struct {
    type: MouseEventType,
    position: [2]f32,
    button: MouseButton,
    wheel_delta: f32,
}

KeyboardEventType :: enum {
    KeyDown,
    KeyUp,
    Character,
}

KeyModifiers :: bit_set[KeyModifier]

KeyModifier :: enum {
    Shift,
    Control,
    Alt,
    Super,
}

KeyboardEvent :: struct {
    type: KeyboardEventType,
    key: i32,
    modifiers: KeyModifiers,
    character: rune,
}

InputState :: struct {
    mouse_pos: [2]f32,
    mouse_buttons: [8]bool,
    keys: [512]bool,
    key_modifiers: KeyModifiers,
}

input_state_init :: proc(state: ^InputState) {
    state.mouse_pos = {0, 0}
    for i in 0..<8 do state.mouse_buttons[i] = false
    for i in 0..<512 do state.keys[i] = false
    state.key_modifiers = {}
}

input_state_update_mouse_pos :: proc(state: ^InputState, x, y: f32) {
    state.mouse_pos = {x, y}
}

input_state_update_mouse_button :: proc(state: ^InputState, button: MouseButton, pressed: bool) {
    if int(button) < len(state.mouse_buttons) {
        state.mouse_buttons[int(button)] = pressed
    }
}

input_state_update_key :: proc(state: ^InputState, key: i32, pressed: bool) {
    if int(key) < len(state.keys) {
        state.keys[int(key)] = pressed
    }
}

input_state_update_modifiers :: proc(state: ^InputState, mods: int) {
    state.key_modifiers = {}
    if mods & int(glfw.MOD_SHIFT) != 0 do state.key_modifiers += {.Shift}
    if mods & int(glfw.MOD_CONTROL) != 0 do state.key_modifiers += {.Control}
    if mods & int(glfw.MOD_ALT) != 0 do state.key_modifiers += {.Alt}
    if mods & int(glfw.MOD_SUPER) != 0 do state.key_modifiers += {.Super}
}

convert_glfw_button :: proc(button: int) -> MouseButton {
    switch button {
    case glfw.MOUSE_BUTTON_LEFT: return .Left
    case glfw.MOUSE_BUTTON_RIGHT: return .Right
    case glfw.MOUSE_BUTTON_MIDDLE: return .Middle
    case: return .Left
    }
}