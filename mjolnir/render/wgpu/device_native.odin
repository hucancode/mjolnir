#+build !js
package wgpu_backend

import "base:intrinsics"
import "vendor:glfw"
import wgpu "vendor:wgpu"
import "vendor:wgpu/glfwglue"

// WindowHandle is the window render draws into: a GLFW window on the desktop.
WindowHandle :: glfw.WindowHandle

// window_size measures the window: its framebuffer in pixels and its content scale. GLFW
// answers on the main thread only.
window_size :: proc(b: ^Backend) -> (framebuffer_size: [2]u32, dpi_scale: f32) {
  w, h := glfw.GetFramebufferSize(b.window)
  sx, _ := glfw.GetWindowContentScale(b.window)
  return {u32(w), u32(h)}, sx
}

@(private)
surface_create :: proc(instance: wgpu.Instance, window: WindowHandle) -> wgpu.Surface {
  // Odin dev-2026-10 asserts on glfwglue's Objective-C calls ("missing procedure
  // objc_lookUpClass") unless a class lookup is generated before them
  when ODIN_OS == .Darwin do _ = intrinsics.objc_find_class("CAMetalLayer")
  return glfwglue.GetSurface(instance, window)
}

// wgpu-native calls back from InstanceProcessEvents: pump until the device is up or failed.
@(private)
device_wait :: proc(b: ^Backend) {
  for !b.up && !b.failed do wgpu.InstanceProcessEvents(b.instance)
}

// Fires the callbacks of finished work (buffer maps).
@(private)
events_process :: proc(b: ^Backend) {
  wgpu.InstanceProcessEvents(b.instance)
}

@(private)
surface_texture_get :: proc(b: ^Backend) -> wgpu.SurfaceTexture {
  return wgpu.SurfaceGetCurrentTexture(b.surface)
}
