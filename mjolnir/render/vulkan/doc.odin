// Package vulkan_backend is the Vulkan backend of render. It changes when Vulkan, or how
// render's frame maps onto it, does; it never imports render or platform and decides nothing.
// It imports rhi, the contract it shares with render and render/wgpu (FrameDesc, Table,
// Vertex, MaterialType, the budgets, ...), and declares the names of its own that render
// aliases in backend.odin and backend_glue.odin: Backend, FRAMES_IN_FLIGHT, RETIRE_GRACE, the
// slot counts that follow from them (MAX_PYRAMID_SLOTS, MAX_DRAW_LIST_SLOTS) and the procs
// (init ... frame).
// rhi.odin is its half of rhi's explicit contract (PROCS).
// It reads render's scene tables as bytes and the rest of each frame, slots and passes
// resolved, from FrameDesc. The window is a GLFW window it makes a Vulkan surface on.
// Below that it wraps Vulkan: GPUContext (instance, device, queues, context.odin), Swapchain,
// Image and Buffer, pipeline helpers, deferred destruction (defer_destroy, memory.odin) and
// batched staging uploads (queue_*, upload.odin). The passes (pass_*.odin) and their shaders
// (shader/) are recorded by frame.odin.
package vulkan_backend
