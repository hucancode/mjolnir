// Package render is the Vulkan renderer: bindless deferred shading with GPU culling.
// Renderer (scene.odin) is the hub: init/shutdown own the device, setup/teardown own a level.
// Each tick, stage_* and attach write scene data, update advances time and frame renders and presents.
// Cameras are in camera.odin, materials, meshes and textures in bindless_*.odin.
// Internals are the passes (pass_*.odin), the per-frame tables (frame_arena.odin) and frame recording (frame.odin).
package render
