// The WebGPU backend of render, on the desktop (wgpu-native, a GLFW window) and the web (a
// canvas): implements rhi's Procs on core WebGPU and WGSL. Only render uses it.
package wgpu_backend

// Layer 1: foundation

// It changes when WebGPU does, never imports render or platform and decides nothing:
// rhi.odin is its half of rhi's contract; render aliases a few more names (backend_glue.odin).
// WebGPU has no bindless arrays, push constants, indirect count, layered rendering, async
// compute or timestamps here, and syncs on its own: textures bind through bind groups, cmd_push
// is a dynamic offset into a uniform ring (pipeline.odin), barriers and upload flushes do
// nothing, and a READBACK buffer is a ring of mappable ones. One frame is in flight.
// device_native.odin and device_js.odin hold what differs between wgpu-native and the
// browser: the surface source, event pumping and surface status.
