// Package render is the renderer: bindless deferred shading with GPU culling, on a GPU
// backend picked at compile time (RENDER_BACKEND, default vulkan).
// Renderer (scene.odin) is the hub: init/shutdown own the backend and what init makes (application
// lifetime); setup/teardown bracket a map, and teardown frees everything made since init in one go.
// Each tick, stage_* and attach write scene data, update advances time and frame renders and presents.
// Cameras are in camera.odin, materials, meshes and textures in bindless_*.odin, CPU geometry in mesh*.odin.
// render makes every decision: handles, scene tables (frame_arena.odin), lights, particles,
// debug lines, overlay batches, and every slot and schedule (draw lists, depth pyramids,
// post-process passes). The backend (render/vulkan) only turns that into GPU work; backend.odin
// and backend_private.odin are the whole boundary. A backend needs persistently mapped
// buffers, bindless sampled textures, storage buffers, compute and indirect draws (Vulkan,
// Metal 3 and D3D12 have them; WebGPU and GL do not).
package render
