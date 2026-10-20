// Draws your scene: meshes, lights, particles, post effects, debug lines and a 2D overlay, and
// runs your own GPU programs (buffers, compute and draw shaders). Create meshes, materials,
// textures, lights, emitters and cameras, attach them to slots (one per world node), feed node
// transforms each tick and call frame.
package render

// Architecture. render is the renderer: deferred shading with GPU culling, on a GPU backend picked
// at compile time (RENDER_BACKEND: vulkan, the default, or wgpu, which also runs on the web).
// Renderer (scene.odin) is the hub: init/shutdown own the backend and what init makes (application
// lifetime); ready finishes init once a backend's device is up (the web hands it over after init
// returns); setup/teardown bracket a map, and teardown frees everything made since init in one go.
// Each tick, stage_* and attach write scene data, update advances time and frame renders and presents.
// Cameras are in camera.odin, materials, meshes and textures in bindless_*.odin, CPU geometry in mesh*.odin.
// render makes every decision. It keeps the one CPU copy of each scene table (tables.odin,
// gpu_data.odin for their layouts) and marks what it writes; flush resolves the frame (slots,
// lights, post-process passes) and frame.odin records it through rhi: the table copies per frame
// in flight (resources.odin), then one file per pass (pass_skin, pass_cull, pass_shadow, pass_material,
// pass_lighting, pass_post, pass_particles, pass_debug_line, pass_overlay; pass_ibl is one-shot),
// with the barriers between them. Shaders are the passes' too: shader/*.slang, one source each for both backends (built
// by make shader, or make shader-wgpu), loaded by the pass that uses them.
// Where the backends differ a pass branches on rhi.Caps (resources.odin: bindless or bind
// groups; pass_cull.odin: compacted multi-draw or per-batch draws, batches.odin; pass_shadow.odin:
// one layered draw or one pass of per-view viewports into a tiled atlas) and shaders keep one
// push layout per pass.
// Its seams are rhi, the contract both sides share, and the backend, which it imports and which
// never imports it: backend.odin (names in render's API) and backend_glue.odin (the rest) are
// the only files naming a backend. It never touches the host: images, environment maps and
// glTF arrive as bytes, the window as platform's handle, its size with each frame.
