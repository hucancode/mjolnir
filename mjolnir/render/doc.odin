// The renderer: deferred PBR shading with GPU culling, shadows, image-based lighting,
// particles, post-processing, debug lines and a 2D overlay. The GPU backend is picked at
// compile time (-define:RENDER_BACKEND=vulkan, the default, or wgpu, which also runs on the web).
//   lifetime: init brings it up on a window, ready reports when the device is up (the web hands
//   it over after init returns), shutdown ends it. setup / teardown bracket a map: teardown frees
//   every camera, mesh, material and texture made since setup in one go; what the application
//   made before setup lives on.
//   resources: mesh_create, material_create, texture_create / texture_load, light_create,
//   emitter_create, forcefield_create, camera_create, environment_map_load; each lives until
//   its *_destroy or teardown. light, emitter, forcefield and material edit one in place.
//   scene: a slot (a world node's index) draws what attach gives it, a mesh, light, emitter or
//   force field. stage_transforms feeds it world.changes each tick, stage_bones a skin palette.
//   each tick: update advances time; stage_overlay gives the frame's 2D overlay (ui, debugui);
//   frame renders and presents.
// It reads no files: images, environment maps and glTF arrive as bytes, the window as platform's handle.
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
// with the barriers between them. Shaders are the passes' too: shader/vulkan (GLSL and its
// SPIR-V, built by make shader) and shader/wgpu (WGSL), loaded by the pass that uses them.
// Where the backends differ a pass branches on rhi.Caps (resources.odin: bindless or bind
// groups; pass_cull.odin: compacted multi-draw or per-batch draws, batches.odin; pass_shadow.odin:
// one layered draw or one pass of per-view viewports into a tiled atlas) and shaders keep one
// push layout per pass.
// Its seams are rhi, the contract both sides share, and the backend, which it imports and which
// never imports it: backend.odin (names in render's API) and backend_glue.odin (the rest) are
// the only files naming a backend. It never touches the host: images, environment maps and
// glTF arrive as bytes, the window as platform's handle, its size with each frame.
