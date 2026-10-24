#+build js
package wgpu_backend

import js "core:sys/wasm/js"
import wgpu "vendor:wgpu"

// WindowHandle is the window render draws into: the CSS selector of a canvas on the web.
WindowHandle :: cstring

// window_size measures the canvas: its size in pixels and the device pixel ratio.
window_size :: proc(b: ^Backend) -> (framebuffer_size: [2]u32, dpi_scale: f32) {
  id := string(b.window)[1:] // the selector is "#" + the canvas id
  w, h := js.get_element_key_f64(id, "width"), js.get_element_key_f64(id, "height")
  return {u32(w), u32(h)}, f32(js.device_pixel_ratio())
}

@(private)
surface_create :: proc(instance: wgpu.Instance, window: WindowHandle) -> wgpu.Surface {
  selector := wgpu.SurfaceSourceCanvasHTMLSelector {
    chain = {sType = .SurfaceSourceCanvasHTMLSelector},
    selector = string(window),
  }
  return wgpu.InstanceCreateSurface(instance, &{nextInChain = &selector.chain})
}

// The browser calls back from its event loop once init has returned: ready waits for it.
@(private)
device_wait :: proc(b: ^Backend) {}

// The browser fires callbacks on its own.
@(private)
events_process :: proc(b: ^Backend) {}

// wgpu.js hands out the canvas texture without a status: having one is success.
@(private)
surface_texture_get :: proc(b: ^Backend) -> wgpu.SurfaceTexture {
  t := wgpu.SurfaceGetCurrentTexture(b.surface)
  if t.texture != nil do t.status = .SuccessOptimal
  return t
}
