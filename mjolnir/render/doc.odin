// Draws your scene (meshes, lights, particles, post effects, debug lines, a 2D overlay) and runs
// your own GPU programs. Create meshes, materials, textures, lights and cameras, attach them to
// slots, place each slot (or stage a scene graph's changes) each tick and call frame.
package render

// Layer 2: systems

// Architecture. render is the renderer: deferred shading with GPU culling, on a GPU backend picked
// at compile time (RENDER_BACKEND: vulkan, the default, or wgpu, which also runs on the web).
// Renderer (scene.odin) is the hub: init/shutdown own the backend and what init makes (application
// lifetime); ready finishes init once a backend's device is up (the web hands it over after init
// returns); setup keeps what the application made so far, and teardown frees everything made after
// the last setup (or init) in one go: one map's resources.
// Each tick, stage_* and attach write scene data, update advances time and frame renders and presents.
// Cameras are in camera.odin, materials in material*.odin, textures in texture.odin, GPU meshes in
// mesh_gpu.odin and CPU geometry in mesh.odin and mesh_builders.odin.
// render makes every decision. It keeps the one CPU copy of each scene table (tables.odin,
// gpu_data.odin for their layouts) and marks what it writes; flush resolves the frame (slots,
// lights, post-process passes) and frame.odin records it through rhi: the table copies per frame
// in flight (resources.odin), then one file per pass (pass_skin, pass_cull, pass_shadow, pass_material,
// pass_lighting, pass_post, pass_particles, pass_debug_line, pass_overlay; pass_ibl is one-shot),
// with the barriers between them. Shaders are the passes' too: shader/*.slang, one source each for both backends (built
// by make shader), loaded by the pass that uses them.
// Where the backends differ a pass branches on the backend's compile-time BINDLESS and
// LAYERED_RENDERING (resources.odin: bindless or bind groups; pass_cull.odin: compacted
// multi-draw or per-batch draws, batches.odin; pass_shadow.odin: one layered draw or one pass of
// per-view viewports into a tiled atlas) or on rhi.Caps (indirect count, first-instance draws,
// async compute), and shaders keep one push layout per pass.
// Its seams are rhi, the contract both sides share, and the backend, which it imports and which
// never imports it: backend.odin (names in render's API) and backend_glue.odin (the rest) are
// the only files naming a backend. It never touches the host: images and environment maps
// arrive as bytes, the window as a GLFW handle (or a canvas selector) and its size with each
// frame.
