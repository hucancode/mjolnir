// The render hardware interface: the contract between render and its GPU backends
// (render/vulkan, render/wgpu). render and each backend import it; it imports neither.
package rhi

// Layer 0: core

// The dependency runs one way, render to backend.
// It knows devices, not scenes. types.odin is the vocabulary of textures and the few budgets a
// device sizes itself by; device.odin is the rest: buffers, bind layouts and groups, pipelines
// (shaders arrive as ShaderSource, SPIR-V or WGSL, from the pass that owns them), command lists
// with passes, draws, dispatches, upload flushes, batched barriers and label scopes, submission
// with sync points, and the device's lifecycle and frame pacing (frame_wait, frame_begin, submit
// with `present`, frame_present, frame_timings). Nothing happens implicitly: uploads land where
// the caller flushes them, the swapchain is touched only by the submission marked present.
// Caps says what the device can do (bindless, indirect count, layered rendering, explicit
// barriers, async compute, timestamps, parallel recording) and render branches on it; a backend never emulates a capability behind the caller's back.
// Each backend declares PROCS :: rhi.Procs(Backend, WindowHandle), whose assignment is the
// conformance check, and render calls those procs directly, so none of it costs a dispatch.
// pool.odin is the handle storage both backends keep their objects in.
// To add a backend, implement Procs; to add a pass, write it in render.
