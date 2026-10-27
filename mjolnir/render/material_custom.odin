package render

import "rhi"

// MaterialShader is a user material shader made by material_shader_create, drawing the
// .CUSTOM materials whose Material.shader it is; 0 is none.
MaterialShader :: distinct u32

// material_shader_create makes a material shader from a compiled user shader whose fragment
// stage is its fs_main and, optionally, a vs_main that moves the mesh's vertices (procedural
// animation, defining CUSTOM_VERTEX before including material.slang); without one the vertex
// stage is render's. Its materials draw in the forward pass, after the built-in forward types,
// over the lit image: depth-tested, blended by `blend`, and writing depth unless `depth_write`
// is false (so nearer meshes hide farther ones drawn after them; a blended shader that discards
// nothing may want it off). They cast no shadow, are not occlusion-culled, are culled by the
// mesh's bounds (keep moved vertices near them) and see only the sun (View.sun_direction,
// sun_radiance). There is room for MAX_MATERIAL_SHADERS at once.
//
// Write the shader in Slang against shader/material.slang, which declares the scene buffers, the
// mesh vertex stage's outputs and the material's textures; load the compiled result with
// #load("name." + SHADER_EXT). It reads the material's params (Material.params), render's time
// and the image size there.
material_shader_create :: proc(
  self: ^Renderer,
  source: []u8,
  blend: BlendMode = .ALPHA,
  cull: CullMode = .BACK,
  depth_write := true,
) -> (
  shader: MaterialShader,
  ok: bool,
) #optional_ok {
  slot := -1
  for p, i in self.custom_material_pipelines {
    if p == 0 {
      slot = i
      break
    }
  }
  if slot < 0 do return 0, false
  desc := rhi.GraphicsPipelineDesc {
    shader        = source,
    layout        = pipeline_layout(self, .MESH, .MATERIAL),
    vertex        = mesh_vertex_streams(),
    cull          = cull,
    color_formats = material_pass_formats(.FORWARD),
    blend         = blend,
    depth         = material_pass_depth(.FORWARD, opaque = depth_write),
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

