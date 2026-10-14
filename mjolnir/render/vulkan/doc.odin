// Package vulkan_backend is the Vulkan backend of render. Its half of the boundary is every
// name render aliases in backend.odin and backend_glue.odin, each declared next to the code
// it belongs to; another backend exports the same names. It never imports render and decides
// nothing: it reads render's scene tables as bytes and the rest of each frame, slots and passes
// resolved, from FrameDesc.
// Below that it wraps Vulkan: GPUContext (instance, device, queues, context.odin), Swapchain,
// Image and Buffer, pipeline helpers, deferred destruction (defer_destroy, memory.odin) and
// batched staging uploads (queue_*, upload.odin). The passes (pass_*.odin) and their shaders
// (shader/) are recorded by frame.odin.
package vulkan_backend
