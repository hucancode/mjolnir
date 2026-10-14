// Package render is the renderer: deferred shading with GPU culling, on a GPU backend picked
// at compile time (RENDER_BACKEND: vulkan, the default, or wgpu, which also runs on the web).
// Renderer (scene.odin) is the hub: init/shutdown own the backend and what init makes (application
// lifetime); ready finishes init once a backend's device is up (the web hands it over after init
// returns); setup/teardown bracket a map, and teardown frees everything made since init in one go.
// Each tick, stage_* and attach write scene data, update advances time and frame renders and presents.
// Cameras are in camera.odin, materials, meshes and textures in bindless_*.odin, CPU geometry in mesh*.odin.
// render makes every decision: handles, scene tables (tables.odin), lights, particles,
// debug lines, overlay batches, and every slot and schedule (draw lists, depth pyramids,
// post-process passes). It keeps the one CPU copy of each table and marks what it writes;
// each frame the backend (render/vulkan, render/wgpu) brings its GPU copies up to date and
// turns the rest of FrameDesc into GPU work. backend.odin and backend_glue.odin are the whole
// boundary, and the only files naming a backend.
package render
