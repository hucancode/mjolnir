// The WebGPU backend of render, on the desktop (wgpu-native, a GLFW window) and the web (a
// canvas): implements rhi's Procs on core WebGPU and WGSL. Only render uses it.
package wgpu_backend

// Layer 1: foundation

// It changes when WebGPU does; it never imports render or platform and decides nothing.
// It is the graphics API behind rhi: rhi.odin is its half of rhi's contract (PROCS), the rest is
// what that needs (PROCS, lifecycle included). Beside PROCS render takes only the names it
// aliases in backend_glue.odin: Backend, FRAMES_IN_FLIGHT, RETIRE_GRACE and the slot counts that
// follow from them.
// WebGPU has no bindless arrays, push constants, indirect count, layered rendering, async
// compute or timestamps here, and syncs on its own: render binds textures through bind groups,
// cmd_push becomes a dynamic offset into a ring of uniform entries (pipeline.odin), barriers and
// upload flushes do nothing, label scopes are debug groups, and a READBACK buffer is a ring of
// mappable ones. Indirect draws of consecutive commands are one multi-draw on wgpu-native and a
// draw each on the web; indirect first instance is taken where the adapter has it. One frame is in flight; queue order is the only sync. device_native.odin
// and device_js.odin hold what differs between wgpu-native and the browser's WebGPU: the surface
// source (GLFW window, canvas selector), event pumping and wgpu.js's surface status. The surface
// follows the window's size, which window_size measures.
