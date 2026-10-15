// Package rhi is the render hardware interface: the contract between render and its GPU
// backends (render/vulkan, render/wgpu). It is a leaf: render and each backend import it, it
// imports neither, so the dependency still runs one way, render to backend.
// It declares what both sides must agree on, once: the data contract (Vertex, Table and the
// layout of render's scene tables, MaterialType, LightType, AttachmentType, texture formats
// and descriptors, post-process effects) and the budgets (MAX_*, *_VIEW_BASE, ...), and
// today FrameDesc, the description of one frame the backend turns into GPU work.
// device.odin is the explicit half: buffers, bind layouts and groups, pipelines (named by
// Shader, whose sources each backend ships), command lists with passes, draws, dispatches and
// barriers, submission with sync points, and frame pacing (frame_wait, frame_begin, submit,
// frame_present). Caps says what the device can do (bindless, push constants, indirect count,
// layered rendering, explicit barriers, async compute) and render chooses by it. Each backend
// declares PROCS :: rhi.Procs(Backend), whose assignment is the conformance check.
// FrameDesc and the pass types (PostPass, ParticleSystemParams, UIBatch, FrameCamera) are on
// their way out: passes are moving into render, which records them through those procs,
// leaving backends only the graphics API (see the render package comment).
package rhi
