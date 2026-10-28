// The Vulkan backend of render: implements rhi's Procs on Vulkan for a GLFW window. Only
// render uses it.
package vulkan_backend

// Layer 1: foundation

// It changes when Vulkan does, never imports render or platform and decides nothing:
// rhi.odin is its half of rhi's contract; render aliases a few more names (backend_glue.odin).
// Vulkan is bindless and renders layers together; it takes push constants, draws with indirect
// count, runs compute on its own queue where there is one, and leaves every hazard to the
// caller's barriers. Pipelines of one interface share a layout, so a set binds once for all.
// Command lists come from a transient pool per recording thread, queue and frame slot, reset by
// frame_wait. Below rhi: GPUContext (context.odin), Swapchain, Image, Buffer sub-allocated from
// large blocks (allocator.odin), deferred destruction (memory.odin) and batched staging uploads
// (upload.odin).
