package platform

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import "../input"
import "vendor:glfw"
import vk "vendor:vulkan"

// A GLFW window that writes device events into `input`. Must not move after
// init (the window callbacks keep a pointer to it).
Platform :: struct {
  window:   glfw.WindowHandle,
  input:    input.Accumulator,
  context_: runtime.Context,
}

init :: proc(self: ^Platform, width, height: u32, title: string) -> bool {
  if !glfw.Init() {
    log.errorf("Failed to initialize GLFW")
    return false
  }
  if !glfw.VulkanSupported() {
    log.errorf("GLFW: Vulkan Not Supported")
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

shutdown :: proc(self: ^Platform) {
  glfw.DestroyWindow(self.window)
  glfw.Terminate()
}

should_close :: proc(self: ^Platform) -> bool {
  return bool(glfw.WindowShouldClose(self.window))
}

// Pump window events into the input accumulator.
poll_events :: proc(self: ^Platform) {
  glfw.PollEvents()
}

// Instance extensions the window surface needs.
vulkan_instance_extensions :: proc() -> []cstring {
  return glfw.GetRequiredInstanceExtensions()
}

vulkan_get_instance_proc_addr :: proc() -> rawptr {
  return rawptr(glfw.GetInstanceProcAddress)
}

create_surface :: proc(self: ^Platform, instance: vk.Instance) -> (surface: vk.SurfaceKHR, ret: vk.Result) {
  ret = glfw.CreateWindowSurface(instance, self.window, nil, &surface)
  return
}

framebuffer_size :: proc(self: ^Platform) -> [2]u32 {
  w, h := glfw.GetFramebufferSize(self.window)
  return {u32(w), u32(h)}
}

// Content scale (DPI factor) of the window.
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
