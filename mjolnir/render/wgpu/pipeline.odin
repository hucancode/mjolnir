#+private
package wgpu_backend

import rhi "../rhi"

import wgpu "vendor:wgpu"

// WebGPU has no push constants: cmd_push writes into a ring of uniform entries and binds them,
// at a dynamic offset, as the push group of the pipeline: the entry's uniforms and the
// samplers every shader declares at @group(2) (shader/common.slang).
@(private)
UNIFORM_ALIGNMENT :: 256
@(private)
UNIFORM_CAPACITY :: 1 << 20

// Makes the push group's layout and group, and the ring that backs it.
@(private)
frame_group_init :: proc(b: ^Backend) {
  all_stages := wgpu.ShaderStageFlags{.Vertex, .Fragment, .Compute}
  layout_entries := make([dynamic]wgpu.BindGroupLayoutEntry, context.temp_allocator)
  append(&layout_entries, wgpu.BindGroupLayoutEntry{binding = 0, visibility = all_stages, buffer = {type = .Uniform, hasDynamicOffset = true, minBindingSize = UNIFORM_ALIGNMENT}})
  for type in rhi.SamplerType {
    kind: wgpu.SamplerBindingType = .Comparison if type == .SHADOW_COMPARE else .Filtering
    append(&layout_entries, wgpu.BindGroupLayoutEntry{binding = 1 + u32(type), visibility = all_stages, sampler = {type = kind}})
  }
  b.frame_layout = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = uint(len(layout_entries)), entries = raw_data(layout_entries)})
  b.uniform_buffer = buffer_create(b, UNIFORM_CAPACITY, {.Uniform, .CopyDst})
  b.uniforms = make([]u8, UNIFORM_CAPACITY)
  entries := make([dynamic]wgpu.BindGroupEntry, context.temp_allocator)
  append(&entries, wgpu.BindGroupEntry{binding = 0, buffer = b.uniform_buffer, size = UNIFORM_ALIGNMENT})
  for sampler, type in b.samplers do append(&entries, wgpu.BindGroupEntry{binding = 1 + u32(type), sampler = sampler})
  b.frame_group = wgpu.DeviceCreateBindGroup(b.device, &{layout = b.frame_layout, entryCount = uint(len(entries)), entries = raw_data(entries)})
}

@(private)
shader_module :: proc(b: ^Backend, source: string) -> wgpu.ShaderModule {
  wgsl := wgpu.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = source}
  return wgpu.DeviceCreateShaderModule(b.device, &{nextInChain = &wgsl.chain})
}

// Front faces wind counter-clockwise on screen, as in Vulkan: the vertex shaders flip y on
// output (clip_output in shader/common.slang), so primitives land on the same pixels in the same order.
@(private)
FRONT_FACE :: wgpu.FrontFace.CCW

@(private)
BLEND_ALPHA := wgpu.BlendState {
  color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
  alpha = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
}
@(private)
BLEND_ADDITIVE := wgpu.BlendState {
  color = {operation = .Add, srcFactor = .One, dstFactor = .One},
  alpha = {operation = .Add, srcFactor = .One, dstFactor = .One},
}
// The header's Max is 5, but an unpatched vendor:wgpu has no BlendOperation.Undefined = 0, so its .Max
// (4) reaches wgpu-native as Min and draws black. The raw value works on native either way; on web it
// needs .github/workflows/wgpu-blend-operation.patch (which also fixes wgpu.js).
@(private)
BLEND_OP_MAX :: wgpu.BlendOperation(5)
@(private)
BLEND_MAX := wgpu.BlendState {
  color = {operation = BLEND_OP_MAX, srcFactor = .One, dstFactor = .One},
  alpha = {operation = BLEND_OP_MAX, srcFactor = .One, dstFactor = .One},
}

@(private)
buffer_create :: proc(b: ^Backend, size: int, usage: wgpu.BufferUsageFlags) -> wgpu.Buffer {
  return wgpu.DeviceCreateBuffer(b.device, &{usage = usage, size = u64((size + 3) &~ 3)})
}
