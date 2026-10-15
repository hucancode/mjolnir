// Package wgpu_backend is the WebGPU backend of render, on the desktop (wgpu-native, a GLFW
// window) and on the web (the browser's WebGPU, a canvas) alike: it uses core WebGPU and WGSL
// only. It changes when WebGPU does; it never imports render or platform and decides nothing.
// It is the graphics API behind rhi: rhi.odin is its half of rhi's contract (PROCS), the rest is
// what that needs (PROCS, lifecycle included). Beside PROCS render takes only the names it
// aliases in backend_glue.odin: Backend, FRAMES_IN_FLIGHT, RETIRE_GRACE and the slot counts that
// follow from them.
// WebGPU has no bindless arrays, push constants, multi-draw, layered rendering or async compute,
// and syncs on its own: render binds textures through bind groups, cmd_push becomes a dynamic offset into
// a ring of uniform entries (pipeline.odin), barriers and upload flushes do nothing, and a READBACK buffer is a
// ring of mappable ones. One frame is in flight; queue order is the only sync. device_native.odin
// and device_js.odin hold what differs between wgpu-native and the browser's WebGPU: the surface
// source (GLFW window, canvas selector), event pumping and wgpu.js's surface status. Neither
// touches the host: the surface follows the framebuffer size render passes, which platform measures.
package wgpu_backend
