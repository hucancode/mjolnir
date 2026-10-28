// The render hardware interface: the contract between render and its GPU backends
// (render/vulkan, render/wgpu). render and each backend import it; it imports neither.
package rhi

// Layer 0: core

// It knows devices, not scenes: types.odin is the vocabulary of textures and budgets,
// device.odin the rest: buffers, bind layouts and groups, pipelines (shaders arrive as SPIR-V
// or WGSL from the pass that owns them), command lists, submission with sync points and frame
// pacing. Nothing happens implicitly: uploads land where the caller flushes them, and only the
// submission marked present touches the swapchain.
// Caps says what the device can do and render branches on it; a backend never emulates a
// capability. Each backend declares PROCS :: rhi.Procs(Backend, WindowHandle), whose
// assignment is the conformance check; render calls the procs directly, with no dispatch.
// pool.odin is the handle storage both backends keep their objects in.
// To add a backend, implement Procs; to add a pass, write it in render.
