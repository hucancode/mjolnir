// Package gpu wraps Vulkan setup and resources for the renderer: GPUContext
// (instance, device, queues), Swapchain, Image and Buffer, pipeline helpers,
// deferred destruction (defer_destroy) and batched staging uploads (queue_*).
// Context setup lives in context.odin, retire and upload machinery in
// memory.odin and upload.odin.
package gpu
