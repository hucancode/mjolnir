// Draws your scene (meshes, lights, particles, post effects, debug lines, a 2D overlay) and runs
// your own GPU programs. Create meshes, materials, textures, lights and cameras, attach them to
// slots, place each slot (or stage a scene graph's changes) each tick and call frame.
package render

// Layer 2: systems

// Architecture. Deferred shading with GPU culling, on a backend picked at compile time
// (RENDER_BACKEND: vulkan, the default, or wgpu, which also runs on the web).
// Renderer (renderer.odin) is the hub. init/shutdown own the backend and what init makes; ready
// finishes init once the device is up (the web hands it over late); teardown frees everything
// made after init in one go: one map.
// Each tick stage_* and attach write scene data, update advances time, frame renders.
// render keeps the one CPU copy of each scene table (tables.odin, layouts in gpu_data.odin)
// and marks what it writes; flush resolves the frame (slots, lights, post effects) and
// frame.odin records it through rhi: the dirty table regions per frame in flight, then the
// passes in the order frame_run calls them, one pass_*.odin file each (the G-buffer and forward
// passes are pass_material.odin), each owning its pipelines and shader/*.slang sources (one
// source for both backends, built by make shader).
// Where backends differ a pass branches on the backend's compile-time BINDLESS or on rhi.Caps.
// The seams are rhi, the contract both sides share, and backend.odin/backend_glue.odin, the
// only files naming a backend. render never touches the host: images arrive as bytes, the
// window as a GLFW handle (or a canvas selector), which frame measures.
