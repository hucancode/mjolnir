package render

import "../containers"

// MaterialShader is a user material shader made by material_shader_create, drawing the
// .CUSTOM materials whose Material.shader it is; 0 is none.
MaterialShader :: distinct u32

// material_shader_create makes a material shader from a compiled user shader whose fragment
// stage is its fs_main and, optionally, a vs_main that moves the mesh's vertices (procedural
// animation, defining CUSTOM_VERTEX before including material.slang); without one the vertex
// stage is render's. Its materials draw in the forward pass, after the built-in forward types,
// over the lit image: depth-tested, culled by `cull`, blended by `blend`, and writing depth unless `depth_write`
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
  guard(self)
  shader = MaterialShader(containers.slots_alloc(&self.slots[.MATERIAL_SHADERS]) or_return)
  pipeline, created := material_pipeline_create(self, .FORWARD, {source = source, cull = cull, blend = blend, opaque = depth_write})
  if !created {
    containers.slots_free(&self.slots[.MATERIAL_SHADERS], u32(shader))
    return 0, false
  }
  self.custom_material_pipelines[shader - 1] = pipeline
  return shader, true
}

// material_shader_destroy frees a shader from material_shader_create; its materials draw
// nothing until they get another.
material_shader_destroy :: proc(self: ^Renderer, shader: MaterialShader) {
  guard(self)
  if !containers.slots_free(&self.slots[.MATERIAL_SHADERS], u32(shader)) do return
  dev.pipeline_retire(&self.gpu, self.custom_material_pipelines[shader - 1])
  self.custom_material_pipelines[shader - 1] = 0
}

