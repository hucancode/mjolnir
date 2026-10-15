// Package vulkan_backend is the Vulkan backend of render. It changes when Vulkan, or how
// render's frame maps onto it, does; it never imports render or platform and decides nothing.
// Its half of the boundary is every name render aliases in backend.odin and backend_glue.odin,
// each declared next to the code it belongs to, in two kinds:
//   the contract, declared identically by every backend and changed only when render asks:
//   FrameDesc and FrameCamera, Table and TABLE_REGIONS, MeshStream and MeshData, Vertex,
//   Vertex2D, UIBatch, TextureHandle, TextureFormat, TextureDesc, AttachmentType and
//   ATTACHMENTS, MaterialType, LightType, the post-process effects and PostPass,
//   ParticleSystemParams, and the budgets (MAX_*, *_VIEW_BASE, SHADOW_MAP_SIZE, ...);
//   its own: Backend, FRAMES_IN_FLIGHT, RETIRE_GRACE, the slot counts that follow from them
//   (MAX_PYRAMID_SLOTS, MAX_DRAW_LIST_SLOTS) and the procs (init ... frame).
// It reads render's scene tables as bytes and the rest of each frame, slots and passes
// resolved, from FrameDesc. The window is a GLFW window it makes a Vulkan surface on.
// Below that it wraps Vulkan: GPUContext (instance, device, queues, context.odin), Swapchain,
// Image and Buffer, pipeline helpers, deferred destruction (defer_destroy, memory.odin) and
// batched staging uploads (queue_*, upload.odin). The passes (pass_*.odin) and their shaders
// (shader/) are recorded by frame.odin.
package vulkan_backend
