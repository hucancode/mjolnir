// Package wgpu_backend is the WebGPU backend of render, on the desktop (wgpu-native, a GLFW
// window) and on the web (the browser's WebGPU, a canvas) alike: it uses core WebGPU and WGSL
// only. It changes when WebGPU, or how render's frame maps onto it, does; it never imports
// render or platform and decides nothing. Its half of the boundary is every name render aliases
// in backend.odin and backend_glue.odin, the contract and its own names as render/vulkan
// lists them, declaring the contract identically. It reads render's scene tables as bytes and
// the rest of each frame, slots and passes resolved, from FrameDesc.
// WebGPU has no bindless arrays, push constants, multi-draw or layered rendering, and syncs on
// its own: textures reach shaders through cached bind groups (textures.odin), push constants
// become dynamic uniform offsets (pipeline.odin), the GPU cull writes one indirect draw per
// candidate node that the CPU issues one by one (cull.odin), and shadow views render one pass
// each. One frame is in flight; queue order is the only sync. device_native.odin and
// device_js.odin hold what differs between wgpu-native and the browser's WebGPU: the surface
// source (GLFW window, canvas selector), event pumping and wgpu.js's surface status. Neither
// touches the host: the surface follows FrameDesc.framebuffer_size, which platform measures.
package wgpu_backend
