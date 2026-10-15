#+build js
package wgpu_backend

import wgpu "vendor:wgpu"

// WindowHandle is the window render draws into: the CSS selector of a canvas on the web.
WindowHandle :: cstring

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
