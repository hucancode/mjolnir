// The Vulkan backend of render: implements rhi's Procs on Vulkan for a GLFW window. Only
// render uses it.
package vulkan_backend

// Layer 1: foundation

// It changes when Vulkan does; it never
// imports render or platform and decides nothing. It is the graphics API behind rhi: rhi.odin
// is its half of rhi's contract (PROCS, lifecycle included), the rest is what that needs. Beside
// PROCS render takes only the names it aliases in backend_glue.odin: Backend, FRAMES_IN_FLIGHT,
// RETIRE_GRACE and the slot counts that follow from them (MAX_PYRAMID_SLOTS, MAX_DRAW_LIST_SLOTS).
// Vulkan is bindless (the global arrays of textures.odin, written through rhi's bindless_write),
// takes push constants, draws with indirect count, renders layers together, runs compute on its
// own queue where the device has one and leaves every hazard to the caller's barriers: those
// are Caps. Staged uploads land where the caller records cmd_flush_uploads, and only the
// submission the caller marks present touches the swapchain. Pipelines of one interface share a
// pipeline layout, so a command list binds a set once for all of them, and UPLOAD buffers sit
// in mappable device memory where there is room. Command lists come from a transient pool per
// recording thread, queue and frame slot, reset whole by frame_wait, so threads record apart;
// label scopes are debug-utils labels and, with host query reset, timestamps read back once
// their slot is waited for. Below rhi it wraps Vulkan: GPUContext (instance, device, queues,
// context.odin), Swapchain, Image and Buffer, whose memory is a range of a large block
// (allocator.odin), pipeline helpers, deferred destruction (defer_destroy, memory.odin) and
// batched staging uploads (queue_*, upload.odin). The window is a GLFW window it makes a Vulkan surface on. It owns no shaders,
// scene data or passes: render does.
