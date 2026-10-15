// Package wgpu_backend is the WebGPU backend of render, on the desktop (wgpu-native, a GLFW
// window) and on the web (the browser's WebGPU, a canvas) alike: it uses core WebGPU and WGSL
// only. It changes when WebGPU, or how render's frame maps onto it, does; it never imports
// render or platform and decides nothing. Its half of the boundary is rhi, the contract it
// shares with render and render/vulkan, and the names of its own that render aliases in
// backend.odin and backend_glue.odin. It reads render's scene tables as bytes and the rest of
// each frame, slots and passes resolved, from FrameDesc.
// rhi.odin is its half of rhi's explicit contract (PROCS).
// WebGPU has no bindless arrays, push constants, multi-draw or layered rendering, and syncs on
// its own: textures reach shaders through cached bind groups (textures.odin), push constants
// become dynamic uniform offsets (pipeline.odin), render batches nodes by mesh and
// material, the GPU cull counts and lists each batch's visible nodes, and the CPU issues one
// indirect draw per batch (cull.odin); shadow views render one pass each. One frame is in flight; queue order is the only sync. device_native.odin and
// device_js.odin hold what differs between wgpu-native and the browser's WebGPU: the surface
// source (GLFW window, canvas selector), event pumping and wgpu.js's surface status. Neither
// touches the host: the surface follows FrameDesc.framebuffer_size, which platform measures.
package wgpu_backend
