#+build !js
package platform

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "../input"
import "vendor:glfw"

// Platform is a GLFW window. Must not move after init (the window callbacks keep a pointer
// to it). `window` is the GLFW handle a renderer draws into.
Platform :: struct {
  window:  glfw.WindowHandle,
  using _: Platform_State,
}

@(private)
Platform_State :: struct {
  // device events since the last read_input
  input:    input.State,
  // the framebuffer size and DPI scale as of the last poll_events
  size:     [2]u32,
  dpi:      f32,
  // guards input, size and dpi: poll_events (main thread) writes them, the update thread reads
  mutex:    sync.Mutex,
  context_: runtime.Context,
  // where the window was before going fullscreen: x, y, width, height
  windowed: [4]c.int,
}

// init opens a window `width` by `height` titled `title`; false on failure.
init :: proc(self: ^Platform, width, height: u32, title: string) -> bool {
  if !glfw.Init() {
    log.errorf("Failed to initialize GLFW")
    return false
  }
  glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
  title_cstr := strings.clone_to_cstring(title, context.temp_allocator)
  self.window = glfw.CreateWindow(c.int(width), c.int(height), title_cstr, nil, nil)
  if self.window == nil {
    log.errorf("Failed to create GLFW window")
    return false
  }
  self.context_ = context
  glfw.SetWindowUserPointer(self.window, self)
  glfw.SetKeyCallback(self.window, key_callback)
  glfw.SetMouseButtonCallback(self.window, mouse_button_callback)
  glfw.SetCursorPosCallback(self.window, cursor_callback)
  glfw.SetScrollCallback(self.window, scroll_callback)
  glfw.SetCharCallback(self.window, char_callback)
  x, y := glfw.GetCursorPos(self.window)
  input.cursor_event(&self.input, {f32(x), f32(y)})
  query_window(self)
  return true
}

// shutdown destroys the window and terminates GLFW.
shutdown :: proc(self: ^Platform) {
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
}

// should_close reports whether the user asked to close the window.
should_close :: proc(self: ^Platform) -> bool {
  return bool(glfw.WindowShouldClose(self.window))
}

// poll_events collects the window events and gamepad states read_input then reports. Main
// thread only.
poll_events :: proc(self: ^Platform) {
  sync.guard(&self.mutex)
  glfw.PollEvents()
  query_window(self)
  for pad in 0 ..< input.MAX_GAMEPADS {
    gp: glfw.GamepadState
    if !glfw.JoystickIsGamepad(c.int(pad)) || !glfw.GetGamepadState(c.int(pad), &gp) {
      input.gamepad_event(&self.input, pad, false)
      continue
    }
    buttons: input.GamepadButtonSet
    for b in input.GamepadButton do if gp.buttons[b] == glfw.PRESS do buttons += {b}
    axes := transmute(input.GamepadAxes)gp.axes
    // GLFW triggers rest at -1
    axes[.LEFT_TRIGGER] = (axes[.LEFT_TRIGGER] + 1) / 2
    axes[.RIGHT_TRIGGER] = (axes[.RIGHT_TRIGGER] + 1) / 2
    input.gamepad_event(&self.input, pad, true, buttons, axes)
  }
}

// read_input takes this tick's input snapshot from the events polled so far; safe beside
// poll_events on another thread.
read_input :: proc(self: ^Platform, s: ^input.State) {
  sync.guard(&self.mutex)
  input.drain(&self.input, s)
}

// framebuffer_size returns the framebuffer size in pixels as of the last poll_events.
framebuffer_size :: proc(self: ^Platform) -> [2]u32 {
  sync.guard(&self.mutex)
  return self.size
}

// dpi_scale returns the framebuffer pixels per window coordinate (the cursor's unit) as of the
// last poll_events: the content scale where the OS scales windows (macOS), else 1.
dpi_scale :: proc(self: ^Platform) -> f32 {
  sync.guard(&self.mutex)
  return self.dpi
}

// set_fullscreen covers the primary monitor with the window at its video mode, or puts the
// window back where it was. Main thread only.
set_fullscreen :: proc(self: ^Platform, on: bool) {
  if on == is_fullscreen(self) do return
  if !on {
    w := self.windowed
    glfw.SetWindowMonitor(self.window, nil, w.x, w.y, w.z, w.w, glfw.DONT_CARE)
    return
  }
  monitor := glfw.GetPrimaryMonitor()
  mode := glfw.GetVideoMode(monitor)
  if mode == nil do return
  x, y := glfw.GetWindowPos(self.window)
  w, h := glfw.GetWindowSize(self.window)
  self.windowed = {x, y, w, h}
  glfw.SetWindowMonitor(self.window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
}

// is_fullscreen reports whether the window covers a monitor. Main thread only.
is_fullscreen :: proc(self: ^Platform) -> bool {
  return glfw.GetWindowMonitor(self.window) != nil
}

// set_cursor_mode shows, hides or locks the cursor over the window. Main thread only.
set_cursor_mode :: proc(self: ^Platform, mode: CursorMode) {
  glfw_mode := [CursorMode]c.int{.NORMAL = glfw.CURSOR_NORMAL, .HIDDEN = glfw.CURSOR_HIDDEN, .LOCKED = glfw.CURSOR_DISABLED}
  glfw.SetInputMode(self.window, glfw.CURSOR, glfw_mode[mode])
}

// set_title sets the window's title. Main thread only.
set_title :: proc(self: ^Platform, title: string) {
  glfw.SetWindowTitle(self.window, strings.clone_to_cstring(title, context.temp_allocator))
}

// get_clipboard returns the clipboard's text, allocated; empty when it holds none. Main thread
// only.
get_clipboard :: proc(self: ^Platform, allocator := context.allocator) -> string {
  return strings.clone(glfw.GetClipboardString(self.window), allocator)
}

// set_clipboard puts text on the clipboard. Main thread only.
set_clipboard :: proc(self: ^Platform, text: string) {
  glfw.SetClipboardString(self.window, strings.clone_to_cstring(text, context.temp_allocator))
}

// Reads the window's size and scale, which GLFW reports on the main thread only.
@(private = "file")
query_window :: proc(self: ^Platform) {
  w, h := glfw.GetFramebufferSize(self.window)
  self.size = {u32(w), u32(h)}
  ww, _ := glfw.GetWindowSize(self.window)
  self.dpi = f32(w) / f32(max(ww, 1)) if w > 0 else 1
}

// run calls step until it returns false, then returns.
run :: proc(step: proc() -> bool) {
  for step() {}
}

// ready does nothing: the window shows the first frame as it comes.
ready :: proc() {}

// fail does nothing: the error is in the log already.
fail :: proc() {}

// sleep blocks the calling thread for `ms` milliseconds.
sleep :: proc(ms: f64) {
  time.sleep(time.Duration(ms * f64(time.Millisecond)))
}

// read_file reads the file at path into memory the caller frees; false when it cannot.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) #optional_ok {
  err: os.Error
  data, err = os.read_entire_file(path, allocator)
  if err != nil {
    log.errorf("Failed to read '%s': %v", path, err)
    return nil, false
  }
  return data, true
}

// write_file writes data to the file at path, replacing it; false when it cannot.
write_file :: proc(path: string, data: []u8) -> bool {
  if err := os.write_entire_file(path, data); err != nil {
    log.errorf("Failed to write '%s': %v", path, err)
    return false
  }
  return true
}

@(private = "file")
platform_of :: proc "contextless" (window: glfw.WindowHandle) -> ^Platform {
  return cast(^Platform)glfw.GetWindowUserPointer(window)
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
  self := platform_of(window)
  context = self.context_
  input.key_event(&self.input, input.Key(key), input.Action(action))
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
  self := platform_of(window)
  context = self.context_
  if button < 0 || button > i32(max(input.MouseButton)) do return
  input.button_event(&self.input, input.MouseButton(button), input.Action(action))
}

@(private = "file")
cursor_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
  self := platform_of(window)
  context = self.context_
  input.cursor_event(&self.input, {f32(x), f32(y)})
}

@(private = "file")
scroll_callback :: proc "c" (window: glfw.WindowHandle, dx, dy: f64) {
  self := platform_of(window)
  context = self.context_
  input.scroll_event(&self.input, {f32(dx), f32(dy)})
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, ch: rune) {
  self := platform_of(window)
  context = self.context_
  input.char_event(&self.input, ch)
}
