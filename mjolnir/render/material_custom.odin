package render

import "rhi"

// MaterialShader is a user material shader made by material_shader_create, drawing the
// .CUSTOM materials whose Material.shader it is; 0 is none.
MaterialShader :: distinct u32

// material_shader_create makes a material shader from a user fragment shader and, optionally, a
// user vertex shader that moves the mesh's vertices (procedural animation); without one the
// vertex stage is render's. Its materials draw in the forward pass, after the built-in forward
// types, over the lit image: depth-tested, blended by `blend`, and writing depth when `blend` is
// .NONE (so opaque meshes hide each other, not only the scene behind them). They cast no
// shadow, are not occlusion-culled, are culled by the mesh's bounds (keep moved vertices near
// them) and see only the sun (View.sun_direction, sun_radiance). There is room for
// MAX_MATERIAL_SHADERS at once. A backend uses only its own sources: `*_spirv` on Vulkan,
// `*_wgsl` on WebGPU.
//
// Vulkan: compile against shader/vulkan/include/material.glsl (glslc -I), which declares the
// mesh vertex stage's outputs, the color output, the scene buffers and the textures; a vertex
// shader defines MATERIAL_VERTEX before including it.
// WebGPU: the sources follow common.wgsl, mesh.wgsl and material_custom.wgsl, so they read
// what they declare; they declare `fs_main(in: VertexOut) -> @location(0) vec4f` and
// `vs_main(in: VertexIn) -> VertexOut`.
// Both read the material's params (Material.params), render's time and the image size there.
// Vulkan samples any texture by handle (sample_texture); WebGPU the material's own four
// (albedo_texture, metallic_roughness_texture, normal_texture, emissive_texture).
material_shader_create :: proc(
  self: ^Renderer,
  frag_spirv: []u8,
  frag_wgsl: string,
  blend: BlendMode = .ALPHA,
  cull: CullMode = .BACK,
  vert_spirv: []u8 = nil,
  vert_wgsl: string = "",
) -> (
  shader: MaterialShader,
  ok: bool,
) {
  slot := -1
  for p, i in self.custom_material_pipelines {
    if p == 0 {
      slot = i
      break
    }
  }
  if slot < 0 do return 0, false
  vert_spirv := vert_spirv if vert_spirv != nil else spirv("shader/vulkan/gbuffer/vert.spv")
  vert_wgsl := vert_wgsl if vert_wgsl != "" else wgsl("shader/wgpu/mesh_vertex.wgsl")
  shared := wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/mesh.wgsl"), wgsl("shader/wgpu/material_custom.wgsl"))
  desc := rhi.GraphicsPipelineDesc {
    shader        = {spirv = {vert = vert_spirv, frag = frag_spirv}, wgsl = wgsl_join(shared, vert_wgsl, frag_wgsl)},
    layout        = pipeline_layout(self, .MESH, .MATERIAL),
    vertex        = mesh_vertex_streams(self),
    cull          = cull,
    color_formats = material_pass_formats(.FORWARD),
    blend         = blend,
    depth         = material_pass_depth(.FORWARD, opaque = blend == .NONE),
  }
  pipeline := dev.graphics_pipeline_create(&self.gpu, desc) or_return
  self.custom_material_pipelines[slot] = pipeline
  return MaterialShader(slot + 1), true
}

// material_shader_destroy frees a shader from material_shader_create; its materials draw
// nothing until they get another.
material_shader_destroy :: proc(self: ^Renderer, shader: MaterialShader) {
  if shader == 0 || int(shader) > MAX_MATERIAL_SHADERS do return
  p := &self.custom_material_pipelines[shader - 1]
  if p^ != 0 do dev.pipeline_retire(&self.gpu, p^)
  p^ = 0
}

