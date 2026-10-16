package render

import "rhi"

// MaterialShader is a user fragment shader made by material_shader_create, drawing the
// .CUSTOM materials whose Material.shader it is; 0 is none.
MaterialShader :: distinct u32

// material_shader_create makes a material shader from a user fragment shader. Its materials
// draw in the forward pass, after the built-in forward types, over the lit image: depth-tested
// without writing depth, blended by `blend`. They cast no shadow and are not occlusion-culled.
// There is room for MAX_MATERIAL_SHADERS at once. A backend uses only its own source:
// `frag_spirv` on Vulkan, `frag_wgsl` on WebGPU.
//
// Vulkan: compile against shader/vulkan/include/material.glsl (glslc -I), which declares the
// mesh vertex stage's outputs, the color output, the scene buffers and the textures.
// WebGPU: the source follows common.wgsl, mesh.wgsl and material_custom.wgsl, so it reads
// what they declare; it declares `fs_main(in: VertexOut) -> @location(0) vec4f`.
material_shader_create :: proc(
  r: ^Renderer,
  frag_spirv: []u8,
  frag_wgsl: string,
  blend: BlendMode = .ALPHA,
  cull: CullMode = .BACK,
) -> (
  shader: MaterialShader,
  ok: bool,
) {
  slot := -1
  for p, i in r.custom_material_pipelines {
    if p == 0 {
      slot = i
      break
    }
  }
  if slot < 0 do return 0, false
  vertex := wgsl_join(wgsl("shader/wgpu/common.wgsl"), wgsl("shader/wgpu/mesh.wgsl"), wgsl("shader/wgpu/material_custom.wgsl"))
  desc := rhi.GraphicsPipelineDesc {
    shader        = {spirv = {vert = spirv("shader/vulkan/gbuffer/vert.spv"), frag = frag_spirv}, wgsl = wgsl_join(vertex, frag_wgsl)},
    layout        = pipeline_layout(r, .MESH, .MATERIAL),
    vertex        = mesh_vertex_streams(r),
    cull          = cull,
    color_formats = material_pass_formats(.FORWARD),
    blend         = blend,
    depth         = material_pass_depth(.FORWARD),
  }
  pipeline := dev.graphics_pipeline_create(&r.gpu, desc) or_return
  r.custom_material_pipelines[slot] = pipeline
  return MaterialShader(slot + 1), true
}

// material_shader_destroy frees a shader from material_shader_create; its materials draw
// nothing until they get another.
material_shader_destroy :: proc(r: ^Renderer, shader: MaterialShader) {
  if shader == 0 || int(shader) > MAX_MATERIAL_SHADERS do return
  p := &r.custom_material_pipelines[shader - 1]
  if p^ != 0 do dev.pipeline_retire(&r.gpu, p^)
  p^ = 0
}

