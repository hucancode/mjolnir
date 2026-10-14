package platform

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import "../input"
import "vendor:glfw"

// Platform is a GLFW window that writes device events into `input`. Must not move after
// init (the window callbacks keep a pointer to it).
Platform :: struct {
  window:   glfw.WindowHandle,
  input:    input.Accumulator,
  context_: runtime.Context,
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
  input.on_cursor(&self.input, f32(x), f32(y))
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

// poll_events pumps window events into the input accumulator. Main thread only.
poll_events :: proc(self: ^Platform) {
  glfw.PollEvents()
}

// read_input takes this tick's input snapshot from the events polled so far.
read_input :: proc(self: ^Platform, s: ^input.State) {
  input.new_frame(s, &self.input)
}

// framebuffer_size returns the framebuffer size in pixels.
framebuffer_size :: proc(self: ^Platform) -> [2]u32 {
  w, h := glfw.GetFramebufferSize(self.window)
  return {u32(w), u32(h)}
}

// dpi_scale returns the content scale (DPI factor) of the window.
dpi_scale :: proc(self: ^Platform) -> f32 {
  sw, sh := glfw.GetWindowContentScale(self.window)
  if sw != sh {
    log.warnf("DPI scale x (%v) and y (%v) not the same, using x", sw, sh)
  }
  return sw
}

@(private = "file")
platform_of :: proc "contextless" (window: glfw.WindowHandle) -> ^Platform {
  return cast(^Platform)glfw.GetWindowUserPointer(window)
}

@(private = "file")
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
  self := platform_of(window)
  context = self.context_
  input.on_key(&self.input, input.Key(key), input.Action(action))
}

@(private = "file")
mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
  self := platform_of(window)
  context = self.context_
  if button < 0 || button > i32(max(input.MouseButton)) do return
  input.on_button(&self.input, input.MouseButton(button), input.Action(action))
}

@(private = "file")
cursor_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
  self := platform_of(window)
  context = self.context_
  input.on_cursor(&self.input, f32(x), f32(y))
}

@(private = "file")
scroll_callback :: proc "c" (window: glfw.WindowHandle, dx, dy: f64) {
  self := platform_of(window)
  context = self.context_
  input.on_scroll(&self.input, f32(dx), f32(dy))
}

@(private = "file")
char_callback :: proc "c" (window: glfw.WindowHandle, ch: rune) {
  self := platform_of(window)
  context = self.context_
  input.on_char(&self.input, ch)
}
